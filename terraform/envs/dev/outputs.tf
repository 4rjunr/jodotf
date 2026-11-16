output "api_invoke_url" {
  description = "Default execute-api URL."
  value       = module.request_capture.api_invoke_url
}

output "custom_domain_target" {
  description = "DNS target for the custom domain."
  value       = module.request_capture.custom_domain_target
}

output "records_bucket" {
  description = "Records bucket."
  value       = module.request_capture.records_bucket
}

output "records_queue_arn" {
  description = "Records queue ARN."
  value       = module.request_capture.records_queue_arn
}

output "dlq_arn" {
  description = "DLQ ARN."
  value       = module.request_capture.dlq_arn
}

output "alarm_topic_arn" {
  description = "Alarm topic ARN."
  value       = module.request_capture.alarm_topic_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard."
  value       = module.request_capture.dashboard_name
}
