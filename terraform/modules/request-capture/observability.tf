# ===========================================================================
# Alarm topic (KMS encrypted, TLS only, only CloudWatch alarms may publish)
# ===========================================================================
resource "aws_sns_topic" "alarms" {
  name              = "${local.name}-request-capture-alarms"
  kms_master_key_id = aws_kms_key.this.arn
  tags              = var.tags
}

data "aws_iam_policy_document" "alarms_topic" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:alarm:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms.arn]

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

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.alarms_topic.json
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != null ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ===========================================================================
# Alarms
# ===========================================================================
locals {
  api_dimensions = {
    ApiName = aws_api_gateway_rest_api.this.name
    Stage   = aws_api_gateway_stage.this.stage_name
  }

  alarms = {
    api-5xx = {
      description        = "API Gateway is returning 5XX responses (includes 503 when records cannot be enqueued)."
      namespace          = "AWS/ApiGateway"
      metric_name        = "5XXError"
      dimensions         = local.api_dimensions
      statistic          = "Sum"
      extended_statistic = null
      period             = 300
      evaluation_periods = 1
      threshold          = var.api_5xx_alarm_threshold
      comparison         = "GreaterThanOrEqualToThreshold"
    }
    api-latency-p99 = {
      description        = "API p99 latency is above target."
      namespace          = "AWS/ApiGateway"
      metric_name        = "Latency"
      dimensions         = local.api_dimensions
      statistic          = null
      extended_statistic = "p99"
      period             = 300
      evaluation_periods = 3
      threshold          = var.api_latency_p99_alarm_ms
      comparison         = "GreaterThanThreshold"
    }
    ingest-errors = {
      description        = "Ingest function is raising errors."
      namespace          = "AWS/Lambda"
      metric_name        = "Errors"
      dimensions         = { FunctionName = module.ingest.function_name }
      statistic          = "Sum"
      extended_statistic = null
      period             = 60
      evaluation_periods = 1
      threshold          = 0
      comparison         = "GreaterThanThreshold"
    }
    ingest-throttles = {
      description        = "Ingest function is being throttled (reserved concurrency exhausted)."
      namespace          = "AWS/Lambda"
      metric_name        = "Throttles"
      dimensions         = { FunctionName = module.ingest.function_name }
      statistic          = "Sum"
      extended_statistic = null
      period             = 60
      evaluation_periods = 1
      threshold          = 0
      comparison         = "GreaterThanThreshold"
    }
    enqueue-failures = {
      description        = "Capture records could not be enqueued; clients are receiving 503."
      namespace          = local.metrics_namespace
      metric_name        = "EnqueueFailures"
      dimensions         = { Service = local.ingest_function_name }
      statistic          = "Sum"
      extended_statistic = null
      period             = 60
      evaluation_periods = 1
      threshold          = 0
      comparison         = "GreaterThanThreshold"
    }
    persister-errors = {
      description        = "Persister function invocations are failing."
      namespace          = "AWS/Lambda"
      metric_name        = "Errors"
      dimensions         = { FunctionName = module.persister.function_name }
      statistic          = "Sum"
      extended_statistic = null
      period             = 300
      evaluation_periods = 1
      threshold          = 0
      comparison         = "GreaterThanThreshold"
    }
    persist-failures = {
      description        = "Records are failing to persist to S3 (retried automatically)."
      namespace          = local.metrics_namespace
      metric_name        = "PersistFailures"
      dimensions         = { Service = local.persister_function_name }
      statistic          = "Sum"
      extended_statistic = null
      period             = 300
      evaluation_periods = 1
      threshold          = var.persist_failure_alarm_threshold
      comparison         = "GreaterThanOrEqualToThreshold"
    }
    queue-oldest-message-age = {
      description        = "Persistence is falling behind or stuck."
      namespace          = "AWS/SQS"
      metric_name        = "ApproximateAgeOfOldestMessage"
      dimensions         = { QueueName = aws_sqs_queue.records.name }
      statistic          = "Maximum"
      extended_statistic = null
      period             = 60
      evaluation_periods = 5
      threshold          = var.queue_age_alarm_seconds
      comparison         = "GreaterThanOrEqualToThreshold"
    }
    dlq-not-empty = {
      description        = "Records were dead-lettered and are NOT in S3. Investigate and redrive (see README runbook)."
      namespace          = "AWS/SQS"
      metric_name        = "ApproximateNumberOfMessagesVisible"
      dimensions         = { QueueName = aws_sqs_queue.dlq.name }
      statistic          = "Maximum"
      extended_statistic = null
      period             = 60
      evaluation_periods = 1
      threshold          = 0
      comparison         = "GreaterThanThreshold"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  extended_statistic  = each.value.extended_statistic
  period              = each.value.period
  evaluation_periods  = each.value.evaluation_periods
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

# ===========================================================================
# Dashboard
# ===========================================================================
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${local.name}-request-capture"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "API requests and errors"
          region = local.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", local.api_name, "Stage", var.environment],
            [".", "4XXError", ".", ".", ".", "."],
            [".", "5XXError", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "API latency (p99)"
          region = local.region
          stat   = "p99"
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiName", local.api_name, "Stage", var.environment],
            [".", "IntegrationLatency", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Pipeline throughput"
          region = local.region
          stat   = "Sum"
          period = 60
          metrics = [
            [local.metrics_namespace, "RecordsEnqueued", "Service", local.ingest_function_name],
            [".", "EnqueueFailures", ".", "."],
            [".", "RecordsPersisted", ".", local.persister_function_name],
            [".", "DuplicateDeliveries", ".", "."],
            [".", "PersistFailures", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "End-to-end lag: API receipt -> S3 (ms)"
          region = local.region
          period = 60
          metrics = [
            [local.metrics_namespace, "EndToEndLagMs", "Service", local.persister_function_name, { stat = "p50" }],
            ["...", { stat = "p99" }],
            ["...", { stat = "Maximum" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Queue health"
          region = local.region
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.records.name],
            [".", "ApproximateAgeOfOldestMessage", ".", "."],
            [".", "ApproximateNumberOfMessagesVisible", ".", aws_sqs_queue.dlq.name, { label = "DLQ depth" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "Lambda errors and throttles"
          region = local.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", module.ingest.function_name],
            [".", "Throttles", ".", "."],
            [".", "Errors", ".", module.persister.function_name],
            [".", "Throttles", ".", "."],
          ]
        }
      },
    ]
  })
}
