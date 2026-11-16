# ===========================================================================
# Records bucket
# ===========================================================================
resource "aws_s3_bucket" "records" {
  bucket              = local.records_bucket_name
  object_lock_enabled = local.object_lock_enabled
  force_destroy       = false
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = var.record_retention_days >= var.object_lock_retention_days
      error_message = "record_retention_days must be >= object_lock_retention_days."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "records" {
  bucket                  = aws_s3_bucket.records.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "records" {
  bucket = aws_s3_bucket.records.id

  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled
  }
}

resource "aws_s3_bucket_versioning" "records" {
  bucket = aws_s3_bucket.records.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "records" {
  bucket = aws_s3_bucket.records.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }
    bucket_key_enabled = true # cuts KMS request volume/cost dramatically
  }
}

resource "aws_s3_bucket_object_lock_configuration" "records" {
  count  = local.object_lock_enabled ? 1 : 0
  bucket = aws_s3_bucket.records.id

  rule {
    default_retention {
      mode = var.object_lock_mode
      days = var.object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.records]
}

# Records are small JSON objects (a few KB). Transitions to IA/Glacier are
# intentionally omitted: objects < 128 KB are not transitioned by default and
# would be billed at the 128 KB minimum. Records simply expire.
resource "aws_s3_bucket_lifecycle_configuration" "records" {
  bucket = aws_s3_bucket.records.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-records"
    status = "Enabled"

    filter {
      prefix = "${local.record_key_prefix}/"
    }

    expiration {
      days = var.record_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {
      prefix = "${local.record_key_prefix}/"
    }

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.records]
}

resource "aws_s3_bucket_logging" "records" {
  bucket        = aws_s3_bucket.records.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "s3-access/"

  target_object_key_format {
    partitioned_prefix {
      partition_date_source = "EventTime"
    }
  }

  depends_on = [aws_s3_bucket_policy.access_logs]
}

data "aws_iam_policy_document" "records_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.records.arn, "${aws_s3_bucket.records.arn}/*"]

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

  statement {
    sid       = "DenyTlsBelow12"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.records.arn, "${aws_s3_bucket.records.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }

  statement {
    sid       = "DenyNonKmsUploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.records.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid       = "DenyWrongKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.records.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.this.arn]
    }
  }

  # Only the persister may write records: humans and other workloads cannot
  # inject or overwrite audit data even if their IAM policies would allow it.
  statement {
    sid       = "DenyWritesFromOtherPrincipals"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.records.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [module.persister.role_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "records" {
  bucket = aws_s3_bucket.records.id
  policy = data.aws_iam_policy_document.records_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.records]
}

# ===========================================================================
# Server access log bucket
# S3 server access logging only supports SSE-S3 destinations (not SSE-KMS).
# ===========================================================================
resource "aws_s3_bucket" "access_logs" {
  bucket        = local.access_log_bucket_name
  force_destroy = false
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {
      prefix = "s3-access/"
    }

    expiration {
      days = var.access_log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.access_logs]
}

data "aws_iam_policy_document" "access_logs_bucket" {
  statement {
    sid       = "AllowS3ServerAccessLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs.arn}/s3-access/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.records.arn]
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
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]

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

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}
