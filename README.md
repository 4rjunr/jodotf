# Request Capture: API Gateway → Lambda → SQS → Lambda → S3

Every `POST` to the API is handled by a Lambda function that returns a response
immediately and enqueues a capture record (headers, path, query parameters,
body, response, timestamps) to SQS. A second Lambda persists records to S3
asynchronously, so the API never waits on S3.

```
Client ─HTTPS─► WAF ─► API Gateway (REST, regional) ─► Ingest λ ──SendMessage──► SQS ─► Persister λ ─► S3
                                                          │                       │
                                                          └─ 503 if enqueue fails └─► DLQ (after 5 attempts)
```

## Repository layout

```
src/
  common/observability.py   structured JSON logging + CloudWatch EMF metrics (stdlib only)
  ingest/app.py             API handler: build response, capture, enqueue, respond
  ingest/capture.py         pure record-building and redaction logic
  persister/app.py          SQS consumer: idempotent conditional write to S3
tests/                      unit tests (no AWS access needed)
terraform/
  modules/lambda-function/  reusable function + scoped role + KMS log group + "live" alias
  modules/request-capture/  the whole stack
  envs/{dev,prod}/          root modules with partial S3 backend
.github/workflows/          CI (tests, fmt, validate, tflint, checkov) and OIDC deploy
```

## Stored record (schema_version 1)

Key: `s3://<bucket>/requests/year=YYYY/month=MM/day=DD/hour=HH/<api-request-id>.json`

```json
{
  "schema_version": 1,
  "request_id": "c6af9ac6-...",
  "trace_id": "Root=1-...",
  "timestamps": { "received_at": "...", "received_at_epoch_ms": 0, "processed_at": "...", "persisted_at": "..." },
  "request": {
    "method": "POST", "path": "/v1/payments", "resource": "/{proxy+}", "stage": "prod", "domain_name": "...",
    "headers": { "Content-Type": ["application/json"], "Authorization": ["[REDACTED]"] },
    "query_parameters": { "q": ["1", "2"] },
    "body": { "encoding": "utf-8 | base64", "content": "...", "size_bytes": 14 }
  },
  "client": { "source_ip": "...", "caller_arn": "...", "account_id": "..." },
  "response": { "status_code": 202, "headers": { }, "body": { "encoding": "utf-8", "content": "..." } }
}
```

Headers and query parameters are multi-value so repeated values are preserved.
Textual bodies are stored as UTF-8; anything else as base64 (lossless). Rejected
requests (400/413) are still captured, with the body omitted and `omitted_reason` set.

## Prerequisites

* Terraform >= 1.10, AWS provider 5.80+ or 6.x
* An S3 bucket for Terraform state (versioned, encrypted, Block Public Access on)
* Python 3.13 for running tests locally
* For AWS_IAM auth: the ARNs of the roles that will call the API

## Verified

`pytest` (21 tests), `terraform fmt -check`, `terraform validate` (dev and prod,
AWS provider 6.72 / archive 2.8), `tflint` and `checkov` (240 passed, 0 failed;
10 documented skips) all pass.

## Deploy

```bash
cd terraform/envs/dev
cp backend.hcl.example backend.hcl            # git-ignored
cp terraform.tfvars.example terraform.tfvars  # git-ignored
# edit both files

terraform init -backend-config=backend.hcl
# First time only: pin provider checksums for every platform your team/CI uses, then commit the lock file
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
terraform plan -out=tfplan
terraform apply tfplan
```

If another stack already manages the account-wide API Gateway CloudWatch role in
this region, set `manage_apigw_account_settings = false`.

## Calling the API (AWS_IAM auth)

```bash
pip install awscurl
awscurl --service execute-api --region ap-south-1 -X POST \
  -H 'Content-Type: application/json' -d '{"hello":"world"}' \
  "$(terraform output -raw api_invoke_url)/v1/orders?ref=42"
# => 202 {"status":"accepted","request_id":"..."}
```

The caller's role must be in `allowed_invoker_arns` and have `execute-api:Invoke`
on the API in its own IAM policy (same account) or be allowed by the resource
policy (cross account).

## Response semantics

| Status | Meaning | Record captured? |
|---|---|---|
| 202 | Accepted and enqueued | Yes |
| 400 | Body not decodable | Yes (body omitted) |
| 413 | Body over `max_body_bytes`, or record too large for SQS | Yes (body omitted) |
| 429 | WAF per-IP rate limit or stage throttling | No (visible in WAF/access logs) |
| 503 + `Retry-After` | SQS unavailable after retries; client should retry | No (fail closed) |

## Security decisions

| Control | Implementation |
|---|---|
| Authentication | `AWS_IAM` (SigV4) by default; resource policy denies any principal not in `allowed_invoker_arns`; optional source-IP allow-list |
| Edge protection | WAF: per-IP rate limit (429), IP reputation list, anonymous IP list (Tor/proxies), Common Rule Set, Known Bad Inputs (incl. Log4j); stage throttling |
| Transport | TLS 1.2 minimum on the custom domain; `aws:SecureTransport` deny on S3, SQS and SNS; S3 also denies TLS < 1.2 |
| Encryption at rest | One customer-managed KMS key with rotation for SQS, S3 (with bucket keys), all log groups and SNS |
| Credential leakage | Sensitive headers/query params redacted *before* leaving the ingest function; WAF logs redact auth headers; API execution data tracing disabled; application logs never contain headers or bodies |
| Least privilege | Ingest: `sqs:SendMessage` on one queue. Persister: consume one queue and `s3:PutObject` on `requests/*` only (no read/delete). KMS use restricted via `kms:ViaService` |
| Data integrity | Bucket policy allows writes only from the persister role, only with the pipeline KMS key; versioning; optional Object Lock (GOVERNANCE/COMPLIANCE) |
| S3 exposure | Block Public Access, ACLs disabled (BucketOwnerEnforced), server access logging |
| Key injection | Persister builds object keys only from a validated request id and timestamp |
| Supply chain | Lambda artifacts contain no third-party packages; CI uses GitHub OIDC (no static AWS keys) |
| Repository | No state, tfvars, backend config or credentials committed (see `.gitignore`) |

Deliberately not done (documented in `.checkov.yaml`): Lambdas are not in a VPC
(nothing private is accessed); env vars use the AWS-managed key (they hold no
secrets); code signing is optional.

## Reliability

* **Exactly-once storage on at-least-once delivery.** The key is derived from the
  API Gateway request id and the write uses `If-None-Match: *`; redeliveries get
  412 and are counted as `DuplicateDeliveries`.
* **Partial batch responses.** One bad message never forces the whole batch to retry.
* **Poison messages.** After `max_receive_count` (5) attempts → DLQ (14-day retention) → alarm.
* **Backpressure.** The queue absorbs bursts; `persister_max_concurrency` protects S3/KMS;
  the S3 client uses adaptive retry for `SlowDown`.
* **Safe deploys.** API Gateway and the event source mapping invoke the `live` alias;
  roll back by pointing the alias at the previous version.

## Observability

* Dashboard `<prefix>-<env>-request-capture`: API traffic and latency, pipeline
  throughput, end-to-end lag (API receipt → S3), queue health, Lambda errors.
* X-Ray: one trace across API Gateway → ingest → SQS → persister (trace header propagated in SQS).
* Correlation: the API Gateway request id appears in access logs, both functions' logs,
  the SQS message attributes, S3 object metadata and the object key.
* Alarms → SNS: API 5XX, p99 latency, ingest errors/throttles, enqueue failures,
  persister errors, persist failures, oldest message age, DLQ not empty.

## Runbook

**DLQ alarm fired.** Records are *not* in S3 yet.
1. Find the cause in the persister logs (look for `invalid capture record` or `failed to persist record`).
2. Fix and deploy.
3. Redrive:
   ```bash
   aws sqs start-message-move-task \
     --source-arn "$(terraform output -raw dlq_arn)" \
     --destination-arn "$(terraform output -raw records_queue_arn)"
   ```
Redrive is safe to repeat: writes are idempotent.

**Enqueue failures / 503s.** Check SQS and KMS service health and throttling
(`ThrottlingException` in ingest logs). Clients receive `Retry-After`.

**Queue age rising.** Check persister errors and throttles; raise
`persister_max_concurrency` if S3 is healthy and the backlog is legitimate.

## Querying with Athena

Records use Hive-style partitions, so an Athena table with partition projection
on `year/month/day/hour` can query them without a crawler.

## Limits and tuning

* `max_body_bytes` defaults to 128 KiB to fit the 256 KiB SQS message limit after
  JSON escaping/base64. SQS now supports messages up to 1 MiB; with a recent AWS
  provider, raise `sqs_max_message_size` to `1048576` and `max_body_bytes` to about 700 KiB.
* `AWSManagedRulesCommonRuleSet` → `SizeRestrictions_BODY` is set to COUNT because
  it blocks bodies over 8 KB; the size limit is enforced in the ingest function.
  Run new WAF rules in COUNT first if your payloads may trip XSS/LFI signatures.
* `AWSManagedRulesAnonymousIpList` → `HostingProviderIPList` is set to COUNT so
  callers running in AWS/GCP/Azure are not blocked. Set
  `waf_anonymous_ip_rules_to_count = []` if only end users call the API.
* One S3 object per request is simplest and idempotent. Above a few thousand
  writes per second, add a hash prefix to the key or compact records into larger
  files for long-term retention.
* `ingest_reserved_concurrency` requires enough unreserved account concurrency
  (new accounts may have a low limit; request an increase first).

## Roadmap

Multi-region (S3 replication + active/passive API), Athena table in Terraform,
Lambda code signing, canary deployments with CodeDeploy.
