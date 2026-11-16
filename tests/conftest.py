"""Load each Lambda package in isolation (both define app.py) with test configuration."""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[1] / "src"

os.environ.update(
    {
        "AWS_DEFAULT_REGION": "us-east-1",
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "QUEUE_URL": "https://sqs.us-east-1.amazonaws.com/111111111111/test-records",
        "BUCKET_NAME": "test-records-bucket",
        "KMS_KEY_ARN": "arn:aws:kms:us-east-1:111111111111:key/11111111-2222-3333-4444-555555555555",
        "METRICS_NAMESPACE": "RequestCapture/test",
        "SERVICE_NAME": "test",
        "MAX_BODY_BYTES": "1024",
        "MAX_MESSAGE_BYTES": "16384",
        "REDACT_HEADERS": "authorization,cookie,x-api-key",
        "REDACT_QUERY_PARAMS": "token,api_key",
    }
)


def _load(module_name: str, path: Path, *search_paths: Path):
    for search_path in (SRC / "common", *search_paths):
        if str(search_path) not in sys.path:
            sys.path.insert(0, str(search_path))
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def ingest():
    return _load("ingest_app", SRC / "ingest" / "app.py", SRC / "ingest")


@pytest.fixture(scope="session")
def persister():
    return _load("persister_app", SRC / "persister" / "app.py")
