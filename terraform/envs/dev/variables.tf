variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "aws_account_id" {
  description = "Target AWS account id (provider refuses any other account)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit account id."
  }
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix (2-12 chars)."
  type        = string
}

variable "repository" {
  description = "Source repository, used as a tag."
  type        = string
  default     = "request-capture"
}

variable "api_authorization_type" {
  description = "AWS_IAM or NONE."
  type        = string
  default     = "AWS_IAM"
}

variable "allowed_invoker_arns" {
  description = "Principals allowed to call the API when using AWS_IAM."
  type        = list(string)
  default     = []
}

variable "allowed_source_cidrs" {
  description = "Optional source IP allow-list."
  type        = list(string)
  default     = []
}

variable "custom_domain_name" {
  description = "Optional custom domain."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "ACM certificate ARN for the custom domain."
  type        = string
  default     = null
}

variable "alarm_email" {
  description = "Optional alarm e-mail subscriber."
  type        = string
  default     = null
}

variable "record_retention_days" {
  description = "Record retention in S3."
  type        = number
  default     = 365
}

variable "object_lock_retention_days" {
  description = "Object Lock retention (0 = disabled)."
  type        = number
  default     = 0
}

variable "object_lock_mode" {
  description = "GOVERNANCE or COMPLIANCE."
  type        = string
  default     = "GOVERNANCE"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
  default     = 90
}

variable "ingest_reserved_concurrency" {
  description = "Ingest reserved concurrency (-1 = unreserved)."
  type        = number
  default     = 100
}

variable "api_throttle_rate_limit" {
  description = "Stage rate limit (rps)."
  type        = number
  default     = 500
}

variable "api_throttle_burst_limit" {
  description = "Stage burst limit."
  type        = number
  default     = 1000
}

variable "manage_apigw_account_settings" {
  description = "Manage the region-wide API Gateway CloudWatch role."
  type        = bool
  default     = true
}
