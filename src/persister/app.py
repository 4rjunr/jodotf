"""Persister Lambda: SQS -> S3.

* Idempotent: the object key is derived from the API Gateway request id and the
  write is conditional (If-None-Match: *). A redelivered message gets HTTP 412,
  which is treated as success. At-least-once delivery becomes exactly-once storage.
* Partial batch responses: only failed messages are retried; after
  maxReceiveCount attempts SQS moves them to the dead-letter queue.
* The object key is built only from validated fields, so a malformed message
  cannot write outside the configured prefix.
"""

from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

from observability import Logger, emit_metrics, utc_now_iso

BUCKET_NAME = os.environ["BUCKET_NAME"]
KMS_KEY_ARN = os.environ["KMS_KEY_ARN"]
KEY_PREFIX = os.environ.get("KEY_PREFIX", "requests").strip("/")
SUPPORTED_SCHEMA_VERSIONS = frozenset({1})
_REQUEST_ID_RE = re.compile(r"[A-Za-z0-9-]{8,128}")

logger = Logger()
_S3 = None


class InvalidRecord(ValueError):
    """The message can never be persisted as-is (poison message)."""


def _s3():
    global _S3
    if _S3 is None:
        # Adaptive mode adds client-side rate limiting when S3 returns SlowDown.
        _S3 = boto3.client("s3", config=Config(retries={"mode": "adaptive", "max_attempts": 5}))
    return _S3


def object_key(record: dict[str, Any]) -> str:
    request_id = record.get("request_id")
    if not isinstance(request_id, str) or not _REQUEST_ID_RE.fullmatch(request_id):
        raise InvalidRecord("invalid request_id")
    timestamps = record.get("timestamps")
    received = timestamps.get("received_at_epoch_ms") if isinstance(timestamps, dict) else None
    if isinstance(received, bool) or not isinstance(received, int) or received <= 0:
        raise InvalidRecord("invalid received_at_epoch_ms")
    try:
        dt = datetime.fromtimestamp(received / 1000, tz=timezone.utc)
    except (OverflowError, OSError, ValueError) as exc:
        raise InvalidRecord("received_at_epoch_ms out of range") from exc
    return (
        f"{KEY_PREFIX}/year={dt:%Y}/month={dt:%m}/day={dt:%d}/hour={dt:%H}/{request_id}.json"
    )


def _is_precondition_failed(exc: ClientError) -> bool:
    error = exc.response.get("Error", {})
    meta = exc.response.get("ResponseMetadata", {})
    return error.get("Code") == "PreconditionFailed" or meta.get("HTTPStatusCode") == 412


def persist(message: dict[str, Any]) -> tuple[str, int]:
    """Write one record. Returns (outcome, end_to_end_lag_ms)."""
    try:
        record = json.loads(message["body"])
    except (KeyError, TypeError, json.JSONDecodeError) as exc:
        raise InvalidRecord("message body is not valid JSON") from exc
    if not isinstance(record, dict) or record.get("schema_version") not in SUPPORTED_SCHEMA_VERSIONS:
        raise InvalidRecord("unsupported schema_version")

    key = object_key(record)
    record["timestamps"]["persisted_at"] = utc_now_iso()
    payload = json.dumps(record, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

    try:
        _s3().put_object(
            Bucket=BUCKET_NAME,
            Key=key,
            Body=payload,
            ContentType="application/json",
            IfNoneMatch="*",
            ServerSideEncryption="aws:kms",
            SSEKMSKeyId=KMS_KEY_ARN,
            BucketKeyEnabled=True,
            ChecksumAlgorithm="SHA256",
            Metadata={
                "request-id": record["request_id"],
                "schema-version": str(record["schema_version"]),
            },
        )
        outcome = "written"
    except ClientError as exc:
        if not _is_precondition_failed(exc):
            raise
        outcome = "duplicate"

    lag_ms = max(0, int(time.time() * 1000) - record["timestamps"]["received_at_epoch_ms"])
    return outcome, lag_ms


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    logger.bind(lambda_request_id=getattr(context, "aws_request_id", None))
    failures: list[str] = []
    written = duplicates = invalid = errors = 0
    lags: list[int] = []

    for message in event.get("Records") or []:
        message_id = message.get("messageId")
        receive_count = (message.get("attributes") or {}).get("ApproximateReceiveCount")
        try:
            outcome, lag_ms = persist(message)
        except InvalidRecord as exc:
            invalid += 1
            failures.append(message_id)
            logger.error(
                "invalid capture record; it will be retried and then dead-lettered",
                message_id=message_id,
                receive_count=receive_count,
                reason=str(exc),
            )
        except (ClientError, BotoCoreError) as exc:
            errors += 1
            failures.append(message_id)
            logger.warning(
                "failed to persist record; it will be retried",
                message_id=message_id,
                receive_count=receive_count,
                error_type=type(exc).__name__,
                error=str(exc),
            )
        except Exception:  # noqa: BLE001 - isolate one bad message from the rest of the batch
            errors += 1
            failures.append(message_id)
            logger.exception("unexpected error persisting record", message_id=message_id)
        else:
            if outcome == "written":
                written += 1
            else:
                duplicates += 1
            lags.append(lag_ms)

    emit_metrics(
        {
            "RecordsPersisted": (written, "Count"),
            "DuplicateDeliveries": (duplicates, "Count"),
            "InvalidRecords": (invalid, "Count"),
            "PersistFailures": (errors + invalid, "Count"),
            "EndToEndLagMs": (lags, "Milliseconds"),
        }
    )
    logger.info(
        "batch processed",
        written=written,
        duplicates=duplicates,
        invalid=invalid,
        errors=errors,
    )
    return {"batchItemFailures": [{"itemIdentifier": message_id} for message_id in failures]}
