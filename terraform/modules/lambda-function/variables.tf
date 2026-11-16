variable "function_name" {
  description = "Lambda function name."
  type        = string
}

variable "description" {
  description = "Lambda function description."
  type        = string
  default     = ""
}

variable "source_files" {
  description = "Map of file name inside the zip => absolute path of the source file."
  type        = map(string)
}

variable "build_dir" {
  description = "Directory where the deployment zip is written (git-ignored)."
  type        = string
}

variable "handler" {
  description = "Function entrypoint."
  type        = string
  default     = "app.handler"
}

variable "runtime" {
  description = "Lambda runtime."
  type        = string
  default     = "python3.13"
}

variable "memory_size" {
  description = "Memory in MB."
  type        = number
  default     = 256
}

variable "timeout" {
  description = "Timeout in seconds."
  type        = number
}

variable "reserved_concurrency" {
  description = "Reserved concurrency. -1 means unreserved."
  type        = number
  default     = -1
}

variable "environment" {
  description = "Environment variables. Must never contain secrets."
  type        = map(string)
  default     = {}
}

variable "policy_json" {
  description = "Function-specific least-privilege IAM policy (JSON)."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key used to encrypt the function's log group."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days."
  type        = number
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
