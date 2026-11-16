"""Pure functions that turn an API Gateway (REST, Lambda proxy) event into a capture record.

No AWS SDK calls here, so the whole record format is unit-testable in isolation.
"""

from __future__ import annotations

import base64
import binascii
from datetime import datetime, timezone
from typing import Any, Mapping

SCHEMA_VERSION = 1
REDACTED = "[REDACTED]"

_TEXTUAL_MEDIA_TYPES = frozenset(
    {
        "application/json",
        "application/xml",
        "application/x-www-form-urlencoded",
        "application/javascript",
        "application/graphql",
    }
)


class InvalidBodyEncoding(ValueError):
    """The request body could not be decoded."""


def parse_name_list(raw: str | None) -> frozenset[str]:
    """Parse a comma-separated, case-insensitive list of names."""
    if not raw:
        return frozenset()
    return frozenset(part.strip().lower() for part in raw.split(",") if part.strip())


def _multi_value(event: Mapping[str, Any], multi_key: str, single_key: str) -> dict[str, list[str]]:
    """Prefer API Gateway's multi-value maps so repeated headers/params are preserved."""
    multi = event.get(multi_key)
    if multi:
        return {name: list(values or []) for name, values in multi.items()}
    single = event.get(single_key) or {}
    return {name: [value] for name, value in single.items() if value is not None}


def redact(values: Mapping[str, list[str]], sensitive: frozenset[str]) -> dict[str, list[str]]:
    return {
        name: ([REDACTED] * len(items) if name.lower() in sensitive else list(items))
        for name, items in values.items()
    }


def first_value(values: Mapping[str, list[str]], name: str) -> str | None:
    target = name.lower()
    for key, items in values.items():
        if key.lower() == target and items:
            return items[0]
    return None


def decode_body(event: Mapping[str, Any]) -> bytes:
    body = event.get("body")
    if body is None:
        return b""
    if event.get("isBase64Encoded"):
        try:
            return base64.b64decode(body, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise InvalidBodyEncoding("request body is not valid base64") from exc
    try:
        return body.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise InvalidBodyEncoding("request body is not valid UTF-8") from exc


def is_textual(content_type: str | None) -> bool:
    if not content_type:
        return False
    media_type = content_type.split(";", 1)[0].strip().lower()
    return (
        media_type.startswith("text/")
        or media_type in _TEXTUAL_MEDIA_TYPES
        or media_type.endswith("+json")
        or media_type.endswith("+xml")
    )


def body_document(raw: bytes, content_type: str | None) -> dict[str, Any]:
    """Store textual bodies as readable UTF-8, everything else as base64 (lossless)."""
    if not raw:
        return {"encoding": "utf-8", "content": ""}
    if is_textual(content_type):
        try:
            return {"encoding": "utf-8", "content": raw.decode("utf-8")}
        except UnicodeDecodeError:
            pass
    return {"encoding": "base64", "content": base64.b64encode(raw).decode("ascii")}


def epoch_ms_to_iso(epoch_ms: int) -> str:
    return datetime.fromtimestamp(epoch_ms / 1000, tz=timezone.utc).isoformat(timespec="milliseconds")


def build_record(
    event: Mapping[str, Any],
    *,
    request_id: str,
    received_at_ms: int,
    processed_at_ms: int,
    raw_body: bytes | None,
    body_size: int,
    body_omitted_reason: str | None,
    response: Mapping[str, Any],
    sensitive_headers: frozenset[str],
    sensitive_query: frozenset[str],
    trace_id: str | None,
) -> dict[str, Any]:
    headers = _multi_value(event, "multiValueHeaders", "headers")
    query = _multi_value(event, "multiValueQueryStringParameters", "queryStringParameters")
    context = event.get("requestContext") or {}
    identity = context.get("identity") or {}

    if raw_body is None:
        body: dict[str, Any] = {"encoding": None, "content": None, "omitted_reason": body_omitted_reason}
    else:
        body = body_document(raw_body, first_value(headers, "content-type"))
    body["size_bytes"] = body_size

    return {
        "schema_version": SCHEMA_VERSION,
        "request_id": request_id,
        "trace_id": trace_id,
        "timestamps": {
            "received_at": epoch_ms_to_iso(received_at_ms),
            "received_at_epoch_ms": received_at_ms,
            "processed_at": epoch_ms_to_iso(processed_at_ms),
        },
        "request": {
            "method": event.get("httpMethod"),
            "path": event.get("path"),
            "resource": event.get("resource"),
            "stage": context.get("stage"),
            "domain_name": context.get("domainName"),
            "headers": redact(headers, sensitive_headers),
            "query_parameters": redact(query, sensitive_query),
            "body": body,
        },
        "client": {
            "source_ip": identity.get("sourceIp"),
            "caller_arn": identity.get("userArn"),
            "account_id": identity.get("accountId"),
        },
        "response": {
            "status_code": response["statusCode"],
            "headers": dict(response.get("headers") or {}),
            "body": {
                "encoding": "base64" if response.get("isBase64Encoded") else "utf-8",
                "content": response.get("body"),
            },
        },
    }
