data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  name       = "${var.name_prefix}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region

  api_name                = "${local.name}-api"
  ingest_function_name    = "${local.name}-ingest"
  persister_function_name = "${local.name}-persister"
  metrics_namespace       = "RequestCapture/${local.name}"

  records_bucket_name    = "${local.name}-${local.account_id}-${local.region}-records"
  access_log_bucket_name = "${local.name}-${local.account_id}-${local.region}-s3logs"
  record_key_prefix      = "requests"

  object_lock_enabled = var.object_lock_retention_days > 0

  # Leave headroom under the SQS limit for message attributes.
  max_message_bytes = var.sqs_max_message_size - 8192
}
