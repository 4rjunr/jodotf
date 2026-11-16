from __future__ import annotations

from botocore.exceptions import ClientError


def client_error(code: str, status: int, operation: str) -> ClientError:
    return ClientError(
        {"Error": {"Code": code, "Message": code}, "ResponseMetadata": {"HTTPStatusCode": status}},
        operation,
    )


class FakeSQS:
    def __init__(self, fail: bool = False) -> None:
        self.fail = fail
        self.sent: list[dict] = []

    def send_message(self, **kwargs):
        if self.fail:
            raise client_error("ServiceUnavailable", 503, "SendMessage")
        self.sent.append(kwargs)
        return {"MessageId": "m-1"}


class FakeS3:
    def __init__(self, fail_keys: set[str] | None = None) -> None:
        self.objects: dict[str, dict] = {}
        self.fail_keys = fail_keys or set()

    def put_object(self, **kwargs):
        key = kwargs["Key"]
        if key in self.fail_keys:
            raise client_error("InternalError", 500, "PutObject")
        if kwargs.get("IfNoneMatch") == "*" and key in self.objects:
            raise client_error("PreconditionFailed", 412, "PutObject")
        self.objects[key] = kwargs
        return {"ETag": '"etag"'}
