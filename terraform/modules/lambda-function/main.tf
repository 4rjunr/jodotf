# Deterministic zip built from explicit files (no stray local files get packaged).
data "archive_file" "this" {
  type        = "zip"
  output_path = "${var.build_dir}/${var.function_name}.zip"

  dynamic "source" {
    for_each = var.source_files
    content {
      filename = source.key
      content  = file(source.value)
    }
  }
}

# Created before the function so retention and KMS apply from the first log line.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = "${var.function_name}-role"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
  tags                 = var.tags
}

# Scoped to this function's own log group only (no AWSLambdaBasicExecutionRole wildcard).
data "aws_iam_policy_document" "base" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  statement {
    sid       = "XRayTracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"] # X-Ray does not support resource-level permissions.
  }
}

resource "aws_iam_role_policy" "base" {
  name   = "base"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.base.json
}

resource "aws_iam_role_policy" "function" {
  name   = "function"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

resource "aws_lambda_function" "this" {
  function_name                  = var.function_name
  description                    = var.description
  role                           = aws_iam_role.this.arn
  runtime                        = var.runtime
  handler                        = var.handler
  architectures                  = ["arm64"]
  memory_size                    = var.memory_size
  timeout                        = var.timeout
  filename                       = data.archive_file.this.output_path
  source_code_hash               = data.archive_file.this.output_base64sha256
  publish                        = true
  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = var.environment
  }

  tracing_config {
    mode = "Active"
  }

  tags = var.tags

  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy.base,
    aws_iam_role_policy.function,
  ]
}

# Callers (API Gateway, SQS event source mapping) always target the alias,
# so a rollback is a single alias update to a previous version.
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.this.function_name
  function_version = aws_lambda_function.this.version
}
