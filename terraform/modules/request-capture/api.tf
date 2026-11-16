# ===========================================================================
# REST API (regional). Chosen over HTTP API for WAF, resource policies,
# X-Ray tracing and customizable gateway responses.
# ===========================================================================
resource "aws_api_gateway_rest_api" "this" {
  name        = local.api_name
  description = "Request capture API (${var.environment})"

  # Every request body arrives base64-encoded, so binary payloads are captured
  # losslessly; the ingest function decodes textual content types for readability.
  binary_media_types = ["*/*"]

  # With a custom domain, force all traffic through it (TLS policy, WAF, DNS control).
  disable_execute_api_endpoint = var.custom_domain_name != null

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "{proxy+}"
}

locals {
  # POST on "/" and on every sub-path.
  api_resources = {
    root  = aws_api_gateway_rest_api.this.root_resource_id
    proxy = aws_api_gateway_resource.proxy.id
  }
}

resource "aws_api_gateway_method" "post" {
  #checkov:skip=CKV2_AWS_53:Endpoint accepts arbitrary payloads by design; size/encoding are validated in the ingest function
  for_each = local.api_resources

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = each.value
  http_method   = "POST"
  authorization = var.api_authorization_type
}

resource "aws_api_gateway_integration" "post" {
  for_each = aws_api_gateway_method.post

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = each.value.resource_id
  http_method             = each.value.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = module.ingest.alias_invoke_arn
  timeout_milliseconds    = 29000
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id   = "AllowApiGatewayInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = module.ingest.function_name
  qualifier      = module.ingest.alias_name
  principal      = "apigateway.amazonaws.com"
  source_arn     = "${aws_api_gateway_rest_api.this.execution_arn}/*/POST/*"
  source_account = local.account_id
}

# ---------------------------------------------------------------------------
# Resource policy
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "api" {
  # Authentication (SigV4) is enforced by the method's AWS_IAM authorization;
  # the explicit Deny below restricts *which* principals may call.
  statement {
    sid       = "AllowInvoke"
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.this.execution_arn}/*/POST/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.api_authorization_type == "AWS_IAM" ? [1] : []

    content {
      sid       = "DenyUnlistedPrincipals"
      effect    = "Deny"
      actions   = ["execute-api:Invoke"]
      resources = ["${aws_api_gateway_rest_api.this.execution_arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnNotLike"
        variable = "aws:PrincipalArn"
        values   = var.allowed_invoker_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.allowed_source_cidrs) > 0 ? [1] : []

    content {
      sid       = "DenyUnlistedSourceIps"
      effect    = "Deny"
      actions   = ["execute-api:Invoke"]
      resources = ["${aws_api_gateway_rest_api.this.execution_arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "NotIpAddress"
        variable = "aws:SourceIp"
        values   = var.allowed_source_cidrs
      }
    }
  }
}

resource "aws_api_gateway_rest_api_policy" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  policy      = data.aws_iam_policy_document.api.json

  lifecycle {
    precondition {
      condition     = var.api_authorization_type != "AWS_IAM" || length(var.allowed_invoker_arns) > 0
      error_message = "allowed_invoker_arns must not be empty when api_authorization_type = AWS_IAM."
    }
  }
}

# ---------------------------------------------------------------------------
# Gateway responses: JSON errors with request id, no internal details,
# security headers on every error.
# ---------------------------------------------------------------------------
locals {
  gateway_error_template = "{\"message\":$context.error.messageString,\"request_id\":\"$context.requestId\"}"

  gateway_response_headers = {
    "gatewayresponse.header.Cache-Control"             = "'no-store'"
    "gatewayresponse.header.Strict-Transport-Security" = "'max-age=63072000; includeSubDomains'"
    "gatewayresponse.header.X-Content-Type-Options"    = "'nosniff'"
  }

  # REST APIs answer unknown methods with 403 "Missing Authentication Token".
  # With IAM auth the same response also means "unsigned request", so it stays 403;
  # for a public API it is turned into a plain 404.
  gateway_responses = {
    DEFAULT_4XX = { status_code = null, template = local.gateway_error_template }
    DEFAULT_5XX = { status_code = null, template = local.gateway_error_template }
    MISSING_AUTHENTICATION_TOKEN = (
      var.api_authorization_type == "NONE"
      ? { status_code = "404", template = "{\"message\":\"Not found\",\"request_id\":\"$context.requestId\"}" }
      : { status_code = "403", template = local.gateway_error_template }
    )
  }
}

resource "aws_api_gateway_gateway_response" "this" {
  for_each = local.gateway_responses

  rest_api_id         = aws_api_gateway_rest_api.this.id
  response_type       = each.key
  status_code         = each.value.status_code
  response_parameters = local.gateway_response_headers

  response_templates = {
    "application/json" = each.value.template
  }
}

# ---------------------------------------------------------------------------
# Deployment & stage
# ---------------------------------------------------------------------------
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Resource policy and gateway response changes only take effect after a redeploy.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy,
      aws_api_gateway_method.post,
      aws_api_gateway_integration.post,
      aws_api_gateway_gateway_response.this,
      aws_api_gateway_rest_api_policy.this.policy,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.post,
    aws_api_gateway_gateway_response.this,
    aws_api_gateway_rest_api_policy.this,
  ]
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.api_name}/access"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
  tags              = var.tags
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  deployment_id        = aws_api_gateway_deployment.this.id
  stage_name           = var.environment
  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      extendedRequestId  = "$context.extendedRequestId"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      path               = "$context.path"
      resourcePath       = "$context.resourcePath"
      status             = "$context.status"
      protocol           = "$context.protocol"
      responseLength     = "$context.responseLength"
      responseLatency    = "$context.responseLatency"
      integrationLatency = "$context.integration.latency"
      integrationStatus  = "$context.integration.status"
      integrationError   = "$context.integration.error"
      errorMessage       = "$context.error.message"
      sourceIp           = "$context.identity.sourceIp"
      userAgent          = "$context.identity.userAgent"
      callerArn          = "$context.identity.userArn"
      wafResponseCode    = "$context.wafResponseCode"
      xrayTraceId        = "$context.xrayTraceId"
    })
  }

  tags = var.tags

  depends_on = [aws_api_gateway_account.this]
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "ERROR"
    data_trace_enabled     = false # would write full request/response bodies to CloudWatch
    throttling_rate_limit  = var.api_throttle_rate_limit
    throttling_burst_limit = var.api_throttle_burst_limit
  }
}

# ---------------------------------------------------------------------------
# Region-wide API Gateway -> CloudWatch Logs role (required for access and
# execution logging). One per account/region: disable if managed elsewhere.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_cloudwatch" {
  count              = var.manage_apigw_account_settings ? 1 : 0
  name               = "${local.name}-apigw-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  count      = var.manage_apigw_account_settings ? 1 : 0
  role       = aws_iam_role.apigw_cloudwatch[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  count               = var.manage_apigw_account_settings ? 1 : 0
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch[0].arn

  depends_on = [aws_iam_role_policy_attachment.apigw_cloudwatch]
}

# ---------------------------------------------------------------------------
# Optional custom domain (TLS 1.2 minimum)
# ---------------------------------------------------------------------------
resource "aws_api_gateway_domain_name" "this" {
  count = var.custom_domain_name != null ? 1 : 0

  domain_name              = var.custom_domain_name
  regional_certificate_arn = var.certificate_arn
  security_policy          = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.certificate_arn != null
      error_message = "certificate_arn is required when custom_domain_name is set."
    }
  }
}

resource "aws_api_gateway_base_path_mapping" "this" {
  count = var.custom_domain_name != null ? 1 : 0

  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = aws_api_gateway_domain_name.this[0].domain_name
}
