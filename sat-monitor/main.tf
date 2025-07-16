# Terraform para desplegar el monitoreo de Boletines Técnicos SAT
# -------------------------------------------
# Instrucciones:
# 1) Para pruebas locales con LocalStack: terraform apply -var="use_localstack=true"
# 2) Para AWS: terraform apply -var="use_localstack=false"
# 3) Empaqueta tu código Lambda en function.zip en este mismo directorio
# 4) Ajusta variables según tu entorno

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Variables de configuración
variable "use_localstack" {
  description = "Usar LocalStack para pruebas locales"
  type        = bool
  default     = false
}

variable "aws_region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nombre del proyecto"
  type        = string
  default     = "sat-boletines-monitor"
}

variable "environment" {
  description = "Ambiente (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "email_sender" {
  description = "Email del remitente"
  type        = string
  default     = "gardunohugo.ganh@gmail.com"
}

variable "email_recipient" {
  description = "Email del destinatario"
  type        = string
  default     = "gardunohugo.ganh@gmail.com"
}

variable "email_password" {
  description = "Contraseña SMTP para enviar correos"
  type        = string
  sensitive   = true
}


variable "schedule_expression" {
  description = "Expresión de programación para Lambda"
  type        = string
  default     = "rate(1 hour)"
}

variable "lambda_timeout" {
  description = "Timeout de Lambda en segundos"
  type        = number
  default     = 300
}

variable "lambda_memory_size" {
  description = "Memoria de Lambda en MB"
  type        = number
  default     = 512
}

# Locals para configuración condicional
locals {
  bucket_name = var.use_localstack ? "${var.project_name}-local-test" : "${var.project_name}-${var.environment}-${random_string.suffix.result}"
  
  # Configuración de endpoints para LocalStack
  localstack_endpoints = var.use_localstack ? {
    events     = "http://localhost:4566"
    s3         = "http://localhost:4566"
    lambda     = "http://localhost:4566"
    iam        = "http://localhost:4566"
    ses        = "http://localhost:4566"
    logs       = "http://localhost:4566"
    cloudwatch = "http://localhost:4566"
  } : {}
  
  # Tags comunes
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "SAT-Web-Scraping"
  }
}

# String aleatorio para hacer único el nombre del bucket
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Configuración del provider AWS
provider "aws" {
  region = var.aws_region
  
  # Configuración para LocalStack
  dynamic "endpoints" {
    for_each = var.use_localstack ? [1] : []
    content {
      events     = local.localstack_endpoints.events
      s3         = local.localstack_endpoints.s3
      lambda     = local.localstack_endpoints.lambda
      iam        = local.localstack_endpoints.iam
      ses        = local.localstack_endpoints.ses
      logs       = local.localstack_endpoints.logs
      cloudwatch = local.localstack_endpoints.cloudwatch
    }
  }
  
  # Configuración específica para LocalStack
  access_key                  = var.use_localstack ? "test" : null
  secret_key                  = var.use_localstack ? "test" : null
  skip_credentials_validation = var.use_localstack
  skip_requesting_account_id  = var.use_localstack
  skip_metadata_api_check     = var.use_localstack
  s3_use_path_style          = var.use_localstack
}

# Bucket S3 para PDFs y logs
resource "aws_s3_bucket" "boletines" {
  bucket        = local.bucket_name
  force_destroy = true
  
  tags = merge(local.common_tags, {
    Name = "Boletines SAT Storage"
  })
}

# Configuración de versionado del bucket
resource "aws_s3_bucket_versioning" "boletines" {
  bucket = aws_s3_bucket.boletines.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Configuración de ACL del bucket
resource "aws_s3_bucket_acl" "boletines" {
  count      = var.use_localstack ? 0 : 1
  bucket     = aws_s3_bucket.boletines.id
  acl        = "private"
  depends_on = [aws_s3_bucket_ownership_controls.boletines]
}

# Configuración de ownership controls (solo para AWS)
resource "aws_s3_bucket_ownership_controls" "boletines" {
  count  = var.use_localstack ? 0 : 1
  bucket = aws_s3_bucket.boletines.id
  
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Configuración de bloqueo de acceso público (solo para AWS)
resource "aws_s3_bucket_public_access_block" "boletines" {
  count  = var.use_localstack ? 0 : 1
  bucket = aws_s3_bucket.boletines.id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Configuración de cifrado del bucket (solo para AWS)
resource "aws_s3_bucket_server_side_encryption_configuration" "boletines" {
  count  = var.use_localstack ? 0 : 1
  bucket = aws_s3_bucket.boletines.id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Configuración de lifecycle para gestión de objetos (solo para AWS)
resource "aws_s3_bucket_lifecycle_configuration" "boletines" {
  count  = var.use_localstack ? 0 : 1
  bucket = aws_s3_bucket.boletines.id
  
  rule {
    id     = "old_versions_cleanup"
    status = "Enabled"
    
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Política de asunción para Lambda
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Rol de ejecución de Lambda
resource "aws_iam_role" "lambda_role" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  
  tags = merge(local.common_tags, {
    Name = "Lambda Execution Role"
  })
}

# Política IAM para acceso a S3
resource "aws_iam_role_policy" "lambda_s3_policy" {
  name = "${var.project_name}-lambda-s3-policy"
  role = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.boletines.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.boletines.arn
      }
    ]
  })
}

# Política IAM para CloudWatch Logs
resource "aws_iam_role_policy" "lambda_logs_policy" {
  name = "${var.project_name}-lambda-logs-policy"
  role = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = [
        "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-*",
        "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-*:*"
      ]
    }]
  })
}

# Política IAM para SES (solo si no es LocalStack)
resource "aws_iam_role_policy" "lambda_ses_policy" {
  count = var.use_localstack ? 0 : 1
  name  = "${var.project_name}-lambda-ses-policy"
  role  = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ]
      Resource = "*"
    }]
  })
}

# Grupo de logs de CloudWatch
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.project_name}-monitoreo"
  retention_in_days = 14
  
  tags = merge(local.common_tags, {
    Name = "Lambda Logs"
  })
}

# Función Lambda
resource "aws_lambda_function" "monitoreo" {
  function_name = "${var.project_name}-monitoreo"
  filename      = "function.zip"
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  role          = aws_iam_role.lambda_role.arn
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_size
  
  source_code_hash = filebase64sha256("function.zip")
  
  environment {
    variables = {
      S3_BUCKET       = aws_s3_bucket.boletines.bucket
      EMAIL_SENDER    = var.email_sender
      EMAIL_RECIPIENT = var.email_recipient
      EMAIL_PASSWORD   = var.email_password
      ENVIRONMENT     = var.environment
      USE_LOCALSTACK  = var.use_localstack
    }
  }
  
  depends_on = [
    aws_cloudwatch_log_group.lambda_logs,
    aws_iam_role_policy.lambda_logs_policy,
    aws_iam_role_policy.lambda_s3_policy
  ]
  
  tags = merge(local.common_tags, {
    Name = "SAT Monitoring Lambda"
  })
}

# Regla de EventBridge para programación
resource "aws_cloudwatch_event_rule" "lambda_schedule" {
  name                = "${var.project_name}-schedule"
  description         = "Trigger SAT monitoring Lambda"
  schedule_expression = var.schedule_expression
  
  tags = merge(local.common_tags, {
    Name = "Lambda Schedule Rule"
  })
}

# Target de EventBridge
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.lambda_schedule.name
  target_id = "lambda-target"
  arn       = aws_lambda_function.monitoreo.arn
}

# Permiso para que EventBridge invoque Lambda
resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.monitoreo.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_schedule.arn
}

# Métricas de CloudWatch para monitoreo
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count = var.use_localstack ? 0 : 1
  
  alarm_name          = "${var.project_name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "This metric monitors lambda errors"
  alarm_actions       = []
  
  dimensions = {
    FunctionName = aws_lambda_function.monitoreo.function_name
  }
  
  tags = merge(local.common_tags, {
    Name = "Lambda Error Alarm"
  })
}

# Outputs
output "lambda_function_name" {
  description = "Nombre de la función Lambda"
  value       = aws_lambda_function.monitoreo.function_name
}

output "lambda_function_arn" {
  description = "ARN de la función Lambda"
  value       = aws_lambda_function.monitoreo.arn
}

output "s3_bucket_name" {
  description = "Nombre del bucket S3"
  value       = aws_s3_bucket.boletines.bucket
}

output "s3_bucket_arn" {
  description = "ARN del bucket S3"
  value       = aws_s3_bucket.boletines.arn
}

output "cloudwatch_log_group_name" {
  description = "Nombre del grupo de logs"
  value       = aws_cloudwatch_log_group.lambda_logs.name
}

output "schedule_rule_name" {
  description = "Nombre de la regla de programación"
  value       = aws_cloudwatch_event_rule.lambda_schedule.name
}

output "environment_info" {
  description = "Información del ambiente"
  value = {
    use_localstack = var.use_localstack
    environment    = var.environment
    region         = var.aws_region
  }
}