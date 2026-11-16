module "request_capture" {
  source = "../../modules/request-capture"

  name_prefix        = var.name_prefix
  environment        = var.environment
  aws_region         = var.aws_region
  lambda_source_root = abspath("${path.root}/../../../src")
  build_dir          = "${path.root}/.build"

  api_authorization_type = var.api_authorization_type
  allowed_invoker_arns   = var.allowed_invoker_arns
  allowed_source_cidrs   = var.allowed_source_cidrs
  custom_domain_name     = var.custom_domain_name
  certificate_arn        = var.certificate_arn

  api_throttle_rate_limit     = var.api_throttle_rate_limit
  api_throttle_burst_limit    = var.api_throttle_burst_limit
  ingest_reserved_concurrency = var.ingest_reserved_concurrency

  record_retention_days      = var.record_retention_days
  object_lock_retention_days = var.object_lock_retention_days
  object_lock_mode           = var.object_lock_mode
  log_retention_days         = var.log_retention_days

  alarm_email                   = var.alarm_email
  manage_apigw_account_settings = var.manage_apigw_account_settings
}
