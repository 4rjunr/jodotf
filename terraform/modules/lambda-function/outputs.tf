output "function_name" {
  description = "Function name."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Unqualified function ARN."
  value       = aws_lambda_function.this.arn
}

output "alias_name" {
  description = "Name of the live alias."
  value       = aws_lambda_alias.live.name
}

output "alias_arn" {
  description = "ARN of the live alias."
  value       = aws_lambda_alias.live.arn
}

output "alias_invoke_arn" {
  description = "Invoke ARN of the live alias (for API Gateway)."
  value       = aws_lambda_alias.live.invoke_arn
}

output "role_arn" {
  description = "Execution role ARN."
  value       = aws_iam_role.this.arn
}

output "log_group_name" {
  description = "Log group name."
  value       = aws_cloudwatch_log_group.this.name
}
