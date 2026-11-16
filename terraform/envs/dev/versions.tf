terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  # Partial configuration: values come from backend.hcl (git-ignored) or CI.
  # See backend.hcl.example. State is encrypted and locked with S3 native locking.
  backend "s3" {}
}
