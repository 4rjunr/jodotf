from __future__ import annotations

import json

import pytest

from fakes import FakeS3

REQUEST_ID = "c6af9ac6-7b61-11e6-9a41-93e8deadbeef"
EXPECTED_KEY = f"requests/year=2025/month=11/day=16/hour=00/{REQUEST_ID}.json"


def record(**overrides):
    rec = {
        "schema_version": 1,
        "request_id": REQUEST_ID,
        "timestamps": {"received_at_epoch_ms": 1763251200123},
        "request": {},
        "response": {"status_code": 202},
    }
    rec.update(overrides)
    return rec


def message(body, message_id="m-1"):
    return {
        "messageId": message_id,
        "body": body if isinstance(body, str) else json.dumps(body),
        "attributes": {"ApproximateReceiveCount": "1"},
    }


@pytest.fixture
def s3(persister, monkeypatch):
    fake = FakeS3()
    monkeypatch.setattr(persister, "_S3", fake)
    return fake


def test_writes_encrypted_conditional_object(persister, s3):
    result = persister.handler({"Records": [message(record())]}, None)

    assert result == {"batchItemFailures": []}
    put = s3.objects[EXPECTED_KEY]
    assert put["IfNoneMatch"] == "*"
    assert put["ServerSideEncryption"] == "aws:kms"
    assert put["SSEKMSKeyId"] == persister.KMS_KEY_ARN
    assert put["ChecksumAlgorithm"] == "SHA256"
    stored = json.loads(put["Body"])
    assert stored["timestamps"]["persisted_at"]


def test_duplicate_delivery_is_success(persister, s3):
    persister.handler({"Records": [message(record())]}, None)
    result = persister.handler({"Records": [message(record(), "m-2")]}, None)
    assert result == {"batchItemFailures": []}
    assert len(s3.objects) == 1


def test_poison_message_isolated_from_batch(persister, s3):
    good = message(record())
    bad = message("{not json", "bad-1")
    result = persister.handler({"Records": [good, bad]}, None)
    assert result == {"batchItemFailures": [{"itemIdentifier": "bad-1"}]}
    assert EXPECTED_KEY in s3.objects


@pytest.mark.parametrize("request_id", ["../../etc/passwd", "a/b/c/d/e/f", "", "short", None, 123])
def test_rejects_unsafe_request_ids(persister, s3, request_id):
    result = persister.handler({"Records": [message(record(request_id=request_id), "x")]}, None)
    assert result == {"batchItemFailures": [{"itemIdentifier": "x"}]}
    assert s3.objects == {}


def test_rejects_unknown_schema_version(persister, s3):
    result = persister.handler({"Records": [message(record(schema_version=99), "x")]}, None)
    assert result["batchItemFailures"] == [{"itemIdentifier": "x"}]


def test_s3_error_is_retried(persister, monkeypatch):
    monkeypatch.setattr(persister, "_S3", FakeS3(fail_keys={EXPECTED_KEY}))
    result = persister.handler({"Records": [message(record(), "x")]}, None)
    assert result["batchItemFailures"] == [{"itemIdentifier": "x"}]
