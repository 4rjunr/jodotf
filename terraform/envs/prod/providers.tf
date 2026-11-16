provider "aws" {
  region = var.aws_region

  # Guard rail: refuse to run against the wrong account.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Service     = "request-capture"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.repository
    }
  }
}
