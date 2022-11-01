provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

# create an s3 bucket for state storage
resource "aws_s3_bucket" "state-file-backups" {
  bucket = "${var.prefix}-state-files"
}

resource "aws_s3_bucket_acl" "state-file-backups" {
  bucket = aws_s3_bucket.state-file-backups.id
  acl    = "private"
}

resource "aws_s3_bucket_versioning" "state-file-backups" {
  bucket = aws_s3_bucket.state-file-backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state-file-backups" {
  bucket = aws_s3_bucket.state-file-backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state-file-backups" {
  bucket = aws_s3_bucket.state-file-backups.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.state-file-backups-key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_kms_key" "state-file-backups-key" {
  description             = "This key is used to encrypt bucket objects"
  deletion_window_in_days = 10
}

# create webhook
resource "aws_lambda_function" "webhook" {
  function_name           = "${var.prefix}-state-saver-webhook"
  description             = "Receives webhook notifications from TFC and saves state files to S3."
  code_signing_config_arn = aws_lambda_code_signing_config.this.arn
  role                    = aws_iam_role.lambda_exec.arn
  handler                 = "main.lambda_handler"
  runtime                 = "python3.7"
  layers                  = ["arn:aws:lambda:${var.region}:634166935893:layer:vault-lambda-extension:14"]


  s3_bucket = aws_s3_bucket.webhook.bucket
  s3_key    = aws_s3_object.webhook.id

  environment {
    variables = {
      REGION                     = var.region
      S3_BUCKET                  = aws_s3_bucket.state-file-backups.id
      SALT_PATH                  = aws_ssm_parameter.notification_token.name
      TFC_TOKEN_PATH             = aws_ssm_parameter.tfc_token.name
      VAULT_ADDR                 = var.vault_addr
      VAULT_AUTH_ROLE            = "state-saver-lambda",
      VAULT_AUTH_PROVIDER        = "aws",
      VAULT_SECRET_PATH          = "terraform/creds/state-saver",
      VAULT_SECRET_FILE          = "/tmp/vault_secret.json",
      VAULT_DEFAULT_CACHE_ENABLE = true,
      VAULT_DEFAULT_CACHE_TTL    = "5m",
      VAULT_SKIP_VERIFY          = "true"
    }
  }
}

resource "aws_ssm_parameter" "tfc_token" {
  name        = "${var.prefix}-tfc-token"
  description = "Terraform Cloud team token"
  type        = "SecureString"
  value       = var.tfc_token
}

resource "aws_ssm_parameter" "notification_token" {
  name        = "${var.prefix}-tfc-notification-token"
  description = "Terraform Cloud webhook notification token"
  type        = "SecureString"
  value       = var.notification_token
}

resource "aws_s3_bucket" "webhook" {
  bucket = "${var.prefix}-state-saver-webhook"
}

resource "aws_s3_bucket_acl" "webhook" {
  bucket = aws_s3_bucket.webhook.id
  acl    = "private"
}

resource "aws_s3_bucket_public_access_block" "webhook" {
  bucket = aws_s3_bucket.webhook.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "webhook" {
  bucket = aws_s3_bucket.webhook.id
  key    = "v1/webhook.zip"
  source = "${path.module}/files/webhook.zip"

  etag = filemd5("${path.module}/files/webhook.zip")
}

resource "aws_iam_role" "lambda_exec" {
  name = "${var.prefix}-state-saver-webhook-lambda"

  assume_role_policy = data.aws_iam_policy_document.webhook_assume_role_policy_definition.json
}

data "aws_iam_policy_document" "webhook_assume_role_policy_definition" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["lambda.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  role   = aws_iam_role.lambda_exec.name
  name   = "${var.prefix}-state-saver-lambda-webhook-policy"
  policy = data.aws_iam_policy_document.lambda_policy_definition.json
}

data "aws_iam_policy_document" "lambda_policy_definition" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.notification_token.arn, aws_ssm_parameter.tfc_token.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state-file-backups.arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey"]
    resources = [aws_kms_key.state-file-backups-key.arn]
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_lambda_attachment" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"

  # The "/*/*" portion grants access from any method on any resource
  # within the API Gateway REST API.
  source_arn = "${aws_api_gateway_rest_api.webhook.execution_arn}/*/*"
}

# api gateway
resource "aws_api_gateway_rest_api" "webhook" {
  name        = "${var.prefix}-state-saver-webhook"
  description = "TFC webhook receiver for saving state files"
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.webhook.id
  parent_id   = aws_api_gateway_rest_api.webhook.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.webhook.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.webhook.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.webhook.invoke_arn
}

resource "aws_api_gateway_method" "proxy_root" {
  rest_api_id   = aws_api_gateway_rest_api.webhook.id
  resource_id   = aws_api_gateway_rest_api.webhook.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_root" {
  rest_api_id = aws_api_gateway_rest_api.webhook.id
  resource_id = aws_api_gateway_method.proxy_root.resource_id
  http_method = aws_api_gateway_method.proxy_root.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.webhook.invoke_arn
}

resource "aws_api_gateway_deployment" "webhook" {
  depends_on = [
    aws_api_gateway_integration.lambda,
    aws_api_gateway_integration.lambda_root,
  ]

  rest_api_id = aws_api_gateway_rest_api.webhook.id
  stage_name  = "state-saver"
}

resource "aws_signer_signing_profile" "this" {
  platform_id = "AWSLambda-SHA384-ECDSA"
}

resource "aws_lambda_code_signing_config" "this" {
  allowed_publishers {
    signing_profile_version_arns = [
      aws_signer_signing_profile.this.arn,
    ]
  }

  policies {
    untrusted_artifact_on_deployment = "Warn"
  }
}
