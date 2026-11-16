"""Dependency-free structured logging and CloudWatch Embedded Metric Format (EMF).

The Lambda artifacts deliberately ship no third-party packages: smaller attack
surface, no supply-chain exposure and no Lambda layer versions to pin.

Security rule: never pass request headers, query strings or bodies to the
logger. That data belongs only in the encrypted record written to S3.
"""

from __future__ import annotations

import json
import os
import time
import traceback
from datetime import datetime, timezone
from typing import Any

_LEVELS = {"DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40}


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class Logger:
    """Single-line JSON logger writing to stdout (shipped to CloudWatch Logs)."""

    def __init__(self, service: str | None = None) -> None:
        self.service = service or os.environ.get("SERVICE_NAME", "request-capture")
        self._threshold = _LEVELS.get(os.environ.get("LOG_LEVEL", "INFO").upper(), _LEVELS["INFO"])
        self._context: dict[str, Any] = {}

    def bind(self, **fields: Any) -> None:
        """Replace the per-invocation context. Call once at the start of each invocation."""
        self._context = dict(fields)

    def debug(self, message: str, **fields: Any) -> None:
        self._emit("DEBUG", message, fields)

    def info(self, message: str, **fields: Any) -> None:
        self._emit("INFO", message, fields)

    def warning(self, message: str, **fields: Any) -> None:
        self._emit("WARNING", message, fields)

    def error(self, message: str, **fields: Any) -> None:
        self._emit("ERROR", message, fields)

    def exception(self, message: str, **fields: Any) -> None:
        fields["exception"] = traceback.format_exc()
        self._emit("ERROR", message, fields)

    def _emit(self, level: str, message: str, fields: dict[str, Any]) -> None:
        if _LEVELS[level] < self._threshold:
            return
        entry = {
            "timestamp": utc_now_iso(),
            "level": level,
            "service": self.service,
            "message": message,
            **self._context,
            **fields,
        }
        print(json.dumps(entry, default=str), flush=True)


def emit_metrics(
    metrics: dict[str, tuple[Any, str]],
    *,
    namespace: str | None = None,
    service: str | None = None,
) -> None:
    """Publish metrics through EMF.

    ``metrics`` maps metric name -> (value or list of values, CloudWatch unit).
    EMF accepts at most 100 values per metric per document.
    """
    metrics = {k: v for k, v in metrics.items() if not (isinstance(v[0], list) and not v[0])}
    if not metrics:
        return
    namespace = namespace or os.environ.get("METRICS_NAMESPACE", "RequestCapture")
    service = service or os.environ.get("SERVICE_NAME", "request-capture")
    document: dict[str, Any] = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": namespace,
                    "Dimensions": [["Service"]],
                    "Metrics": [{"Name": name, "Unit": unit} for name, (_, unit) in metrics.items()],
                }
            ],
        },
        "Service": service,
    }
    for name, (value, _) in metrics.items():
        document[name] = value[:100] if isinstance(value, list) else value
    print(json.dumps(document), flush=True)
