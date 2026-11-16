# One customer-managed key for this pipeline's data at rest: SQS messages,
# S3 records, CloudWatch log groups and the alarm SNS topic.
data "aws_iam_policy_document" "kms" {
  # In a KMS key policy, resources = ["*"] refers to this key only.
  #checkov:skip=CKV_AWS_109:Key policy resource "*" is scoped to this key
  #checkov:skip=CKV_AWS_111:Key policy resource "*" is scoped to this key
  #checkov:skip=CKV_AWS_356:Key policy resource "*" is scoped to this key
  # Delegates key usage to IAM policies in this account (each role is scoped below).
  statement {
    sid       = "EnableIamPolicies"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid = "AllowCloudWatchLogsEncryption"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }

  # Required for CloudWatch alarms to publish to the KMS-encrypted SNS topic.
  statement {
    sid       = "AllowCloudWatchAlarmsToEncryptedTopic"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${local.name} request-capture pipeline data key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.name}-request-capture"
  target_key_id = aws_kms_key.this.key_id
}
