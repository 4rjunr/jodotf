output "api_invoke_url" {
  description = "Default execute-api URL (disabled when a custom domain is configured)."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "api_id" {
  description = "REST API id."
  value       = aws_api_gateway_rest_api.this.id
}

output "custom_domain_target" {
  description = "Create a DNS alias/CNAME from custom_domain_name to this regional domain."
  value       = try(aws_api_gateway_domain_name.this[0].regional_domain_name, null)
}

output "custom_domain_zone_id" {
  description = "Hosted zone id for a Route 53 alias record to the custom domain."
  value       = try(aws_api_gateway_domain_name.this[0].regional_zone_id, null)
}

output "records_bucket" {
  description = "S3 bucket holding captured records."
  value       = aws_s3_bucket.records.id
}

output "records_queue_url" {
  description = "SQS queue URL."
  value       = aws_sqs_queue.records.url
}

output "records_queue_arn" {
  description = "SQS queue ARN."
  value       = aws_sqs_queue.records.arn
}

output "dlq_arn" {
  description = "Dead-letter queue ARN (used for redrive)."
  value       = aws_sqs_queue.dlq.arn
}

output "kms_key_arn" {
  description = "Pipeline KMS key ARN."
  value       = aws_kms_key.this.arn
}

output "alarm_topic_arn" {
  description = "SNS topic receiving alarm notifications."
  value       = aws_sns_topic.alarms.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "ingest_function_name" {
  description = "Ingest Lambda function name."
  value       = module.ingest.function_name
}

output "persister_function_name" {
  description = "Persister Lambda function name."
  value       = module.persister.function_name
}
