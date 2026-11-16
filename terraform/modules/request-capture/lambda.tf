# ===========================================================================
# Ingest function: API Gateway -> SQS
# ===========================================================================
data "aws_iam_policy_document" "ingest" {
  statement {
    sid       = "SendCaptureRecords"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.records.arn]
  }

  statement {
    sid       = "EncryptQueueMessages"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.this.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sqs.${local.region}.amazonaws.com"]
    }
  }
}

module "ingest" {
  source = "../lambda-function"

  function_name        = local.ingest_function_name
  description          = "Handles POST requests and enqueues a capture record to SQS"
  build_dir            = var.build_dir
  memory_size          = var.ingest_memory_size
  timeout              = var.ingest_timeout
  reserved_concurrency = var.ingest_reserved_concurrency
  policy_json          = data.aws_iam_policy_document.ingest.json
  kms_key_arn          = aws_kms_key.this.arn
  log_retention_days   = var.log_retention_days
  tags                 = var.tags

  source_files = {
    "app.py"           = "${var.lambda_source_root}/ingest/app.py"
    "capture.py"       = "${var.lambda_source_root}/ingest/capture.py"
    "observability.py" = "${var.lambda_source_root}/common/observability.py"
  }

  environment = {
    QUEUE_URL           = aws_sqs_queue.records.url
    MAX_BODY_BYTES      = tostring(var.max_body_bytes)
    MAX_MESSAGE_BYTES   = tostring(local.max_message_bytes)
    REDACT_HEADERS      = join(",", var.redact_headers)
    REDACT_QUERY_PARAMS = join(",", var.redact_query_params)
    METRICS_NAMESPACE   = local.metrics_namespace
    SERVICE_NAME        = local.ingest_function_name
    LOG_LEVEL           = var.log_level
  }
}

# ===========================================================================
# Persister function: SQS -> S3
# ===========================================================================
data "aws_iam_policy_document" "persister" {
  statement {
    sid = "ConsumeCaptureRecords"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.records.arn]
  }

  # Write-only: no GetObject, ListBucket or DeleteObject.
  statement {
    sid       = "WriteRecords"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.records.arn}/${local.record_key_prefix}/*"]
  }

  statement {
    sid       = "UsePipelineKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.this.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "sqs.${local.region}.amazonaws.com",
        "s3.${local.region}.amazonaws.com",
      ]
    }
  }
}

module "persister" {
  source = "../lambda-function"

  function_name      = local.persister_function_name
  description        = "Persists capture records from SQS to S3 (idempotent)"
  build_dir          = var.build_dir
  memory_size        = var.persister_memory_size
  timeout            = var.persister_timeout
  policy_json        = data.aws_iam_policy_document.persister.json
  kms_key_arn        = aws_kms_key.this.arn
  log_retention_days = var.log_retention_days
  tags               = var.tags

  # Concurrency is bounded by the event source mapping's maximum_concurrency.
  # Do not also set reserved concurrency below that value (causes throttling loops).
  reserved_concurrency = -1

  source_files = {
    "app.py"           = "${var.lambda_source_root}/persister/app.py"
    "observability.py" = "${var.lambda_source_root}/common/observability.py"
  }

  environment = {
    BUCKET_NAME       = aws_s3_bucket.records.id
    KMS_KEY_ARN       = aws_kms_key.this.arn
    KEY_PREFIX        = local.record_key_prefix
    METRICS_NAMESPACE = local.metrics_namespace
    SERVICE_NAME      = local.persister_function_name
    LOG_LEVEL         = var.log_level
  }
}

resource "aws_lambda_event_source_mapping" "persister" {
  event_source_arn                   = aws_sqs_queue.records.arn
  function_name                      = module.persister.alias_arn
  batch_size                         = var.persister_batch_size
  maximum_batching_window_in_seconds = var.persister_batching_window_seconds
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.persister_max_concurrency
  }

  lifecycle {
    precondition {
      condition     = var.persister_batch_size <= 10 || var.persister_batching_window_seconds >= 1
      error_message = "persister_batching_window_seconds must be >= 1 when persister_batch_size > 10."
    }
  }

  depends_on = [module.persister]
}
