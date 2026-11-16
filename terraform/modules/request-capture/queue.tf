resource "aws_sqs_queue" "dlq" {
  name                              = "${local.name}-records-dlq"
  message_retention_seconds         = var.dlq_retention_seconds
  max_message_size                  = var.sqs_max_message_size
  kms_master_key_id                 = aws_kms_key.this.arn
  kms_data_key_reuse_period_seconds = 300
  tags                              = var.tags
}

# Standard queue: records are independent, ordering is irrelevant and the
# persister is idempotent, so FIFO's throughput limits buy nothing.
resource "aws_sqs_queue" "records" {
  name                              = "${local.name}-records"
  message_retention_seconds         = var.queue_retention_seconds
  max_message_size                  = var.sqs_max_message_size
  visibility_timeout_seconds        = var.persister_timeout * 6 # AWS guidance for Lambda event sources
  receive_wait_time_seconds         = 20
  kms_master_key_id                 = aws_kms_key.this.arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = var.tags
}

# Only the records queue may use the DLQ (enables native DLQ redrive back to it).
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.records.arn]
  })
}

data "aws_iam_policy_document" "queue_tls_only" {
  for_each = {
    records = aws_sqs_queue.records.arn
    dlq     = aws_sqs_queue.dlq.arn
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "records" {
  queue_url = aws_sqs_queue.records.id
  policy    = data.aws_iam_policy_document.queue_tls_only["records"].json
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.queue_tls_only["dlq"].json
}
