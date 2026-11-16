"""Ingest Lambda: API Gateway REST API (Lambda proxy) -> SQS.

Flow per request:
  1. Build the HTTP response.
  2. Build a capture record (headers/query redacted) that includes that exact response.
  3. Enqueue the record to SQS (bounded retries).
  4. Return the response.

The S3 write happens asynchronously in the persister function, so the API never
waits on S3. If the record cannot be enqueued, the request fails with 503 so the
client retries: the capture guarantee is never silently dropped (fail closed).
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

import capture
from observability import Logger, emit_metrics

QUEUE_URL = os.environ["QUEUE_URL"]
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", "131072"))
MAX_MESSAGE_BYTES = int(os.environ.get("MAX_MESSAGE_BYTES", "253952"))
SENSITIVE_HEADERS = capture.parse_name_list(os.environ.get("REDACT_HEADERS"))
SENSITIVE_QUERY = capture.parse_name_list(os.environ.get("REDACT_QUERY_PARAMS"))
RETRY_AFTER_SECONDS = os.environ.get("RETRY_AFTER_SECONDS", "5")

_SECURITY_HEADERS = {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
    "X-Content-Type-Options": "nosniff",
}

_BODIES = {
    202: {"status": "accepted"},
    400: {"message": "Request body could not be decoded"},
    405: {"message": "Method not allowed"},
    413: {"message": "Request body exceeds the maximum allowed size"},
    500: {"message": "Internal server error"},
    503: {"message": "Service temporarily unavailable, please retry"},
}

logger = Logger()
_SQS = None


def _sqs():
    """Lazily created, reused across warm invocations.

    Worst case with these settings: 3 attempts x (1s connect + 2s read) + backoff,
    which stays inside the function timeout and API Gateway's 29s integration limit.
    """
    global _SQS
    if _SQS is None:
        _SQS = boto3.client(
            "sqs",
            config=Config(
                retries={"mode": "standard", "max_attempts": 3},
                connect_timeout=1,
                read_timeout=2,
            ),
        )
    return _SQS


def _response(status: int, request_id: str, extra_headers: dict[str, str] | None = None) -> dict[str, Any]:
    payload = {**_BODIES[status], "request_id": request_id}
    headers = {**_SECURITY_HEADERS, "X-Request-Id": request_id, **(extra_headers or {})}
    return {
        "statusCode": status,
        "headers": headers,
        "body": json.dumps(payload, separators=(",", ":")),
        "isBase64Encoded": False,
    }


def _enqueue(message: str, request_id: str, trace_id: str | None) -> None:
    params: dict[str, Any] = {
        "QueueUrl": QUEUE_URL,
        "MessageBody": message,
        "MessageAttributes": {
            "request_id": {"DataType": "String", "StringValue": request_id},
            "schema_version": {"DataType": "Number", "StringValue": str(capture.SCHEMA_VERSION)},
        },
    }
    if trace_id:
        # Propagates the X-Ray trace so API -> ingest -> SQS -> persister is one trace.
        params["MessageSystemAttributes"] = {
            "AWSTraceHeader": {"DataType": "String", "StringValue": trace_id}
        }
    _sqs().send_message(**params)


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    request_context = event.get("requestContext") or {}
    lambda_request_id = getattr(context, "aws_request_id", None)
    request_id = request_context.get("requestId") or lambda_request_id or "unknown"
    logger.bind(request_id=request_id, lambda_request_id=lambda_request_id)
    try:
        return _handle(event, request_context, request_id)
    except Exception:  # noqa: BLE001 - last-resort guard, never leak internals to the client
        logger.exception("unhandled error")
        emit_metrics({"UnhandledErrors": (1, "Count")})
        return _response(500, request_id)


def _handle(event: dict[str, Any], request_context: dict[str, Any], request_id: str) -> dict[str, Any]:
    # Only POST is routed by API Gateway; this is defence in depth.
    if (event.get("httpMethod") or "").upper() != "POST":
        return _response(405, request_id, {"Allow": "POST"})

    status, omitted_reason, raw_body = 202, None, b""
    try:
        raw_body = capture.decode_body(event)
    except capture.InvalidBodyEncoding:
        status, omitted_reason = 400, "invalid_encoding"
    else:
        if len(raw_body) > MAX_BODY_BYTES:
            status, omitted_reason = 413, "exceeds_max_body_bytes"

    received_at_ms = int(request_context.get("requestTimeEpoch") or time.time() * 1000)
    trace_id = os.environ.get("_X_AMZN_TRACE_ID")

    def render(code: int, reason: str | None) -> tuple[dict[str, Any], str]:
        response = _response(code, request_id)
        record = capture.build_record(
            event,
            request_id=request_id,
            received_at_ms=received_at_ms,
            processed_at_ms=int(time.time() * 1000),
            raw_body=None if reason else raw_body,
            body_size=len(raw_body),
            body_omitted_reason=reason,
            response=response,
            sensitive_headers=SENSITIVE_HEADERS,
            sensitive_query=SENSITIVE_QUERY,
            trace_id=trace_id,
        )
        # ensure_ascii=True: SQS rejects some valid Unicode code points (e.g. U+FFFE),
        # and pure ASCII also makes len(message) == size in bytes.
        return response, json.dumps(record, separators=(",", ":"), ensure_ascii=True)

    response, message = render(status, omitted_reason)

    # Record too large for SQS (body expanded by escaping/base64): reject, but still capture.
    if len(message) > MAX_MESSAGE_BYTES and omitted_reason is None:
        status, omitted_reason = 413, "exceeds_max_message_bytes"
        response, message = render(status, omitted_reason)

    if len(message) > MAX_MESSAGE_BYTES:
        logger.error("capture record exceeds queue limit even without body", record_bytes=len(message))
        emit_metrics({"RecordsTooLarge": (1, "Count")})
        return _response(413, request_id)

    try:
        _enqueue(message, request_id, trace_id)
    except (BotoCoreError, ClientError) as exc:
        logger.error("failed to enqueue capture record", error_type=type(exc).__name__, error=str(exc))
        emit_metrics({"EnqueueFailures": (1, "Count")})
        return _response(503, request_id, {"Retry-After": RETRY_AFTER_SECONDS})

    metrics: dict[str, tuple[Any, str]] = {"RecordsEnqueued": (1, "Count")}
    if status >= 400:
        metrics["RequestsRejected"] = (1, "Count")
    emit_metrics(metrics)
    logger.info(
        "request captured",
        status_code=status,
        body_bytes=len(raw_body),
        record_bytes=len(message),
        path=event.get("path"),
    )
    return response
