from __future__ import annotations

import base64
import json

import pytest

from fakes import FakeSQS


class Ctx:
    aws_request_id = "lambda-req-1"


def make_event(body: bytes = b'{"amount": 10}', content_type: str = "application/json", **overrides):
    event = {
        "resource": "/{proxy+}",
        "path": "/v1/payments",
        "httpMethod": "POST",
        "headers": {"Content-Type": content_type, "Authorization": "Bearer secret"},
        "multiValueHeaders": {
            "Content-Type": [content_type],
            "Authorization": ["Bearer secret"],
            "Cookie": ["session=abc"],
            "X-Custom": ["a", "b"],
        },
        "queryStringParameters": {"q": "1", "token": "t0ps3cret"},
        "multiValueQueryStringParameters": {"q": ["1", "2"], "token": ["t0ps3cret"]},
        "requestContext": {
            "requestId": "c6af9ac6-7b61-11e6-9a41-93e8deadbeef",
            "requestTimeEpoch": 1763251200123,
            "stage": "prod",
            "domainName": "api.example.com",
            "identity": {"sourceIp": "203.0.113.10", "userArn": "arn:aws:iam::111111111111:role/caller"},
        },
        "body": base64.b64encode(body).decode(),
        "isBase64Encoded": True,
    }
    event.update(overrides)
    return event


@pytest.fixture
def sqs(ingest, monkeypatch):
    fake = FakeSQS()
    monkeypatch.setattr(ingest, "_SQS", fake)
    return fake


def sent_record(sqs):
    assert len(sqs.sent) == 1
    return json.loads(sqs.sent[0]["MessageBody"])


def test_accepts_and_enqueues_full_record(ingest, sqs):
    response = ingest.handler(make_event(), Ctx())

    assert response["statusCode"] == 202
    assert json.loads(response["body"])["request_id"] == "c6af9ac6-7b61-11e6-9a41-93e8deadbeef"
    record = sent_record(sqs)
    assert record["schema_version"] == 1
    assert record["request"]["path"] == "/v1/payments"
    assert record["request"]["body"] == {"encoding": "utf-8", "content": '{"amount": 10}', "size_bytes": 14}
    assert record["request"]["query_parameters"]["q"] == ["1", "2"]
    assert record["request"]["headers"]["X-Custom"] == ["a", "b"]
    assert record["timestamps"]["received_at_epoch_ms"] == 1763251200123
    assert record["response"]["status_code"] == 202
    assert record["response"]["body"]["content"] == response["body"]
    assert sqs.sent[0]["MessageAttributes"]["request_id"]["StringValue"] == record["request_id"]


def test_redacts_credentials_in_headers_and_query(ingest, sqs):
    ingest.handler(make_event(), Ctx())
    message = sqs.sent[0]["MessageBody"]
    record = json.loads(message)

    assert record["request"]["headers"]["Authorization"] == ["[REDACTED]"]
    assert record["request"]["headers"]["Cookie"] == ["[REDACTED]"]
    assert record["request"]["query_parameters"]["token"] == ["[REDACTED]"]
    assert "Bearer secret" not in message and "t0ps3cret" not in message and "session=abc" not in message


def test_binary_body_is_stored_base64(ingest, sqs):
    payload = bytes(range(256))
    ingest.handler(make_event(body=payload, content_type="application/octet-stream"), Ctx())
    body = sent_record(sqs)["request"]["body"]
    assert body["encoding"] == "base64"
    assert base64.b64decode(body["content"]) == payload


def test_oversized_body_rejected_but_still_captured(ingest, sqs):
    response = ingest.handler(make_event(body=b"x" * 2048), Ctx())
    assert response["statusCode"] == 413
    record = sent_record(sqs)
    assert record["request"]["body"]["content"] is None
    assert record["request"]["body"]["omitted_reason"] == "exceeds_max_body_bytes"
    assert record["request"]["body"]["size_bytes"] == 2048
    assert record["response"]["status_code"] == 413


def test_invalid_base64_body_returns_400(ingest, sqs):
    event = make_event()
    event["body"] = "***not-base64***"
    response = ingest.handler(event, Ctx())
    assert response["statusCode"] == 400
    assert sent_record(sqs)["request"]["body"]["omitted_reason"] == "invalid_encoding"


def test_enqueue_failure_fails_closed_with_503(ingest, monkeypatch):
    monkeypatch.setattr(ingest, "_SQS", FakeSQS(fail=True))
    response = ingest.handler(make_event(), Ctx())
    assert response["statusCode"] == 503
    assert response["headers"]["Retry-After"] == "5"


def test_non_post_rejected(ingest, sqs):
    response = ingest.handler(make_event(httpMethod="GET"), Ctx())
    assert response["statusCode"] == 405
    assert sqs.sent == []


def test_xray_trace_header_propagated(ingest, sqs, monkeypatch):
    monkeypatch.setenv("_X_AMZN_TRACE_ID", "Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=1")
    ingest.handler(make_event(), Ctx())
    attrs = sqs.sent[0]["MessageSystemAttributes"]
    assert attrs["AWSTraceHeader"]["StringValue"].startswith("Root=1-5759e988")


def test_message_is_pure_ascii(ingest, sqs):
    ingest.handler(make_event(body="héllo \uffff wörld".encode()), Ctx())
    assert sqs.sent[0]["MessageBody"].isascii()


def test_security_headers_present(ingest, sqs):
    headers = ingest.handler(make_event(), Ctx())["headers"]
    assert headers["Cache-Control"] == "no-store"
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert "Strict-Transport-Security" in headers
