# ---------------------------------------------------------------------------
# Naming / placement
# ---------------------------------------------------------------------------
variable "name_prefix" {
  description = "Short prefix for resource names. Kept short because S3 bucket names are limited to 63 chars."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,11}$", var.name_prefix))
    error_message = "name_prefix must be 2-12 chars of lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment; also used as the API Gateway stage name."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region the stack is deployed to (must match the provider region)."
  type        = string
}

variable "lambda_source_root" {
  description = "Absolute path to the repository's src/ directory."
  type        = string
}

variable "build_dir" {
  description = "Directory for Lambda deployment zips (git-ignored)."
  type        = string
}

# ---------------------------------------------------------------------------
# API access control
# ---------------------------------------------------------------------------
variable "api_authorization_type" {
  description = "AWS_IAM (SigV4, recommended) or NONE (public; protected only by WAF/throttling/IP allow-list)."
  type        = string
  default     = "AWS_IAM"

  validation {
    condition     = contains(["AWS_IAM", "NONE"], var.api_authorization_type)
    error_message = "api_authorization_type must be AWS_IAM or NONE."
  }
}

variable "allowed_invoker_arns" {
  description = "IAM role/user ARNs (wildcards allowed) permitted to call the API when api_authorization_type = AWS_IAM."
  type        = list(string)
  default     = []
}

variable "allowed_source_cidrs" {
  description = "Optional source IP allow-list enforced by the API resource policy. Empty = any IP."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_source_cidrs : can(cidrhost(c, 0))])
    error_message = "allowed_source_cidrs must contain valid CIDR blocks."
  }
}

variable "custom_domain_name" {
  description = "Optional custom domain. When set, the default execute-api endpoint is disabled."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "ACM certificate ARN (same region) for custom_domain_name."
  type        = string
  default     = null
}

variable "api_throttle_rate_limit" {
  description = "Stage-wide steady-state requests per second."
  type        = number
  default     = 500
}

variable "api_throttle_burst_limit" {
  description = "Stage-wide burst limit."
  type        = number
  default     = 1000
}

variable "waf_rate_limit_per_ip" {
  description = "Max requests per source IP per 5-minute window before WAF blocks with 429."
  type        = number
  default     = 2000

  validation {
    condition     = var.waf_rate_limit_per_ip >= 100
    error_message = "waf_rate_limit_per_ip must be at least 100."
  }
}

variable "waf_rules_to_count" {
  description = "Rules in AWSManagedRulesCommonRuleSet switched to COUNT. SizeRestrictions_BODY blocks bodies > 8 KB, so it is counted and the size limit is enforced in the ingest function instead."
  type        = list(string)
  default     = ["SizeRestrictions_BODY"]
}

variable "waf_anonymous_ip_rules_to_count" {
  description = "Rules in AWSManagedRulesAnonymousIpList switched to COUNT. HostingProviderIPList is counted by default so callers running in AWS/GCP/Azure are not blocked; set to [] for browser/end-user traffic only."
  type        = list(string)
  default     = ["HostingProviderIPList"]
}

# ---------------------------------------------------------------------------
# Payload limits and redaction
# ---------------------------------------------------------------------------
variable "max_body_bytes" {
  description = "Maximum accepted request body size. Larger bodies get 413 (the request is still captured, without body)."
  type        = number
  default     = 131072
}

variable "sqs_max_message_size" {
  description = "SQS max message size in bytes. 262144 works with every AWS provider version; SQS now supports up to 1048576 with a recent provider."
  type        = number
  default     = 262144

  validation {
    condition     = var.sqs_max_message_size >= 16384 && var.sqs_max_message_size <= 1048576
    error_message = "sqs_max_message_size must be between 16384 and 1048576."
  }
}

variable "redact_headers" {
  description = "Header names (case-insensitive) whose values are replaced with [REDACTED] before the record leaves the ingest function."
  type        = list(string)
  default = [
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
    "x-amz-security-token",
    "x-auth-token",
    "x-csrf-token",
    "x-xsrf-token",
  ]
}

variable "redact_query_params" {
  description = "Query parameter names (case-insensitive) whose values are redacted."
  type        = list(string)
  default = [
    "token",
    "access_token",
    "id_token",
    "refresh_token",
    "api_key",
    "apikey",
    "password",
    "secret",
    "signature",
    "x-amz-signature",
    "x-amz-credential",
    "x-amz-security-token",
  ]
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------
variable "ingest_memory_size" {
  description = "Ingest function memory (MB)."
  type        = number
  default     = 256
}

variable "ingest_timeout" {
  description = "Ingest function timeout (s). Must stay below API Gateway's 29 s integration timeout."
  type        = number
  default     = 20

  validation {
    condition     = var.ingest_timeout >= 5 && var.ingest_timeout <= 28
    error_message = "ingest_timeout must be between 5 and 28 seconds."
  }
}

variable "ingest_reserved_concurrency" {
  description = "Reserved concurrency for the ingest function (caps blast radius on the account). -1 = unreserved."
  type        = number
  default     = 100
}

variable "persister_memory_size" {
  description = "Persister function memory (MB)."
  type        = number
  default     = 256
}

variable "persister_timeout" {
  description = "Persister function timeout (s). Queue visibility timeout is set to 6x this value."
  type        = number
  default     = 30

  validation {
    condition     = var.persister_timeout >= 5 && var.persister_timeout <= 900
    error_message = "persister_timeout must be between 5 and 900 seconds."
  }
}

variable "persister_batch_size" {
  description = "Max messages per persister invocation."
  type        = number
  default     = 25

  validation {
    condition     = var.persister_batch_size >= 1 && var.persister_batch_size <= 100
    error_message = "persister_batch_size must be between 1 and 100 (EMF caps a metric at 100 values per document)."
  }
}

variable "persister_batching_window_seconds" {
  description = "Max time to gather a batch. Must be >= 1 when batch size > 10."
  type        = number
  default     = 5
}

variable "persister_max_concurrency" {
  description = "Max concurrent persister invocations from the event source mapping (protects S3/KMS during backlog drains)."
  type        = number
  default     = 10

  validation {
    condition     = var.persister_max_concurrency >= 2 && var.persister_max_concurrency <= 1000
    error_message = "persister_max_concurrency must be between 2 and 1000."
  }
}

# ---------------------------------------------------------------------------
# Queue
# ---------------------------------------------------------------------------
variable "max_receive_count" {
  description = "Delivery attempts before a message moves to the DLQ."
  type        = number
  default     = 5
}

variable "queue_retention_seconds" {
  description = "Main queue message retention."
  type        = number
  default     = 345600 # 4 days
}

variable "dlq_retention_seconds" {
  description = "DLQ message retention (max 14 days)."
  type        = number
  default     = 1209600 # 14 days
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------
variable "record_retention_days" {
  description = "Days to keep captured records before lifecycle expiration."
  type        = number
  default     = 365
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep noncurrent object versions."
  type        = number
  default     = 30
}

variable "object_lock_retention_days" {
  description = "S3 Object Lock default retention in days. 0 disables Object Lock. Can only be enabled when the bucket is created."
  type        = number
  default     = 0
}

variable "object_lock_mode" {
  description = "GOVERNANCE (privileged users can override) or COMPLIANCE (nobody, including root, can delete before expiry)."
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "access_log_retention_days" {
  description = "Days to keep S3 server access logs."
  type        = number
  default     = 365
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
variable "log_retention_days" {
  description = "CloudWatch Logs retention for Lambda, API Gateway and WAF logs."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value supported by CloudWatch Logs."
  }
}

variable "log_level" {
  description = "Application log level."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be DEBUG, INFO, WARNING or ERROR."
  }
}

variable "alarm_email" {
  description = "Optional e-mail address subscribed to the alarm topic (requires confirmation)."
  type        = string
  default     = null
}

variable "manage_apigw_account_settings" {
  description = "Manage the region-wide API Gateway CloudWatch Logs role. Set false if another stack in this account/region already manages aws_api_gateway_account."
  type        = bool
  default     = true
}

variable "api_5xx_alarm_threshold" {
  description = "5XX responses per 5 minutes that trigger an alarm."
  type        = number
  default     = 5
}

variable "api_latency_p99_alarm_ms" {
  description = "p99 API latency (ms) alarm threshold."
  type        = number
  default     = 1000
}

variable "queue_age_alarm_seconds" {
  description = "Alarm when the oldest queued record is older than this."
  type        = number
  default     = 300
}

variable "persist_failure_alarm_threshold" {
  description = "Failed persist attempts per 5 minutes that trigger an alarm (individual failures are retried)."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Extra tags for all resources (provider default_tags also apply)."
  type        = map(string)
  default     = {}
}
