terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

terraform {
  backend "s3" {
    bucket = "aravind-terraform-state-bucket-ap-south-1"
    key    = "portfolio-backend/terraform.tfstate"
    region = "ap-south-1"
  }
}


data "aws_caller_identity" "current" {}

# tfsec:ignore:aws-dynamodb-table-customer-key
# tfsec:ignore:aws-dynamodb-enable-recovery 
resource "aws_dynamodb_table" "visitor_counter_table" {
  name         = "PortfolioVisitorCounter"
  billing_mode = "PAY_PER_REQUEST" 
  hash_key     = "ID"

  attribute {
    name = "ID"
    type = "S" 
  }
  server_side_encryption {
    enabled = true
  }
  tags = {
    Project   = "Cloud Resume Challenge"
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "portfolio-lambda-execution-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "lambda.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })
}
resource "aws_iam_policy" "lambda_permissions_policy" {
  name        = "portfolio-lambda-permissions"
  description = "Allows Lambda to write to DynamoDB, CloudWatch Logs, and access ADOT layer"

  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ],
        Resource = aws_dynamodb_table.visitor_counter_table.arn
      },
      {
        Effect   = "Allow",
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
      },
      {
        Effect   = "Allow",
        Action   = [
          "lambda:ListLayerVersions"
        ],
        Resource = "arn:aws:lambda:${var.aws_region}:901920570463:layer:aws-otel-python-amd64-ver-1-32-0:*"
      }
    ]
  })
}


resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_permissions_policy.arn
}

resource "null_resource" "prepare_lambda_package" {
  triggers = {
    counter_py = filebase64sha256("${path.module}/counter.py")
    collector_yaml = filebase64sha256("${path.module}/collector.yaml")
  }

  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/package; cp ${path.module}/counter.py ${path.module}/collector.yaml ${path.module}/package/"
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/package"
  output_path = "${path.module}/counter.zip"

  depends_on = [null_resource.prepare_lambda_package]
}


# tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "visitor_counter_lambda" {
  function_name    = "PortfolioVisitorCounterFunction"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  
  role    = aws_iam_role.lambda_exec_role.arn
  handler = "counter.lambda_handler"
  runtime = "python3.13"
  layers = [
    "arn:aws:lambda:ap-south-1:901920570463:layer:aws-otel-python-amd64-ver-1-32-0:2"
    ]
  environment {
    variables = {
      AWS_LAMBDA_EXEC_WRAPPER             = "/opt/otel-instrument"
      OPENTELEMETRY_COLLECTOR_CONFIG_FILE = "/var/task/collector.yaml"
      ip_hash_secret                      = var.ip_hash_secret 
      table_name                          = aws_dynamodb_table.visitor_counter_table.name
    }
  }
}

resource "aws_api_gateway_rest_api" "portfolio_api" {
  name        = "PortfolioVisitorCounterAPI"
  description = "API to handle visitor count logic for my portfolio website."
}

resource "aws_api_gateway_resource" "visitors_resource" {
  rest_api_id = aws_api_gateway_rest_api.portfolio_api.id
  parent_id   = aws_api_gateway_rest_api.portfolio_api.root_resource_id
  path_part   = "visitors"
}

# tfsec:ignore:aws-api-gateway-no-public-access
resource "aws_api_gateway_method" "post_method" {
  rest_api_id   = aws_api_gateway_rest_api.portfolio_api.id
  resource_id   = aws_api_gateway_resource.visitors_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "post_integration" {
  rest_api_id             = aws_api_gateway_rest_api.portfolio_api.id
  resource_id             = aws_api_gateway_resource.visitors_resource.id
  http_method             = aws_api_gateway_method.post_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY" 
  uri                     = aws_lambda_function.visitor_counter_lambda.invoke_arn
}

# tfsec:ignore:aws-api-gateway-no-public-access
resource "aws_api_gateway_method" "options_method" {
  rest_api_id   = aws_api_gateway_rest_api.portfolio_api.id
  resource_id   = aws_api_gateway_resource.visitors_resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_integration" {
  rest_api_id = aws_api_gateway_rest_api.portfolio_api.id
  resource_id = aws_api_gateway_resource.visitors_resource.id
  http_method = aws_api_gateway_method.options_method.http_method
  type        = "MOCK" 

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_200" {
  rest_api_id = aws_api_gateway_rest_api.portfolio_api.id
  resource_id = aws_api_gateway_resource.visitors_resource.id
  http_method = aws_api_gateway_method.options_method.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.portfolio_api.id
  resource_id = aws_api_gateway_resource.visitors_resource.id
  http_method = aws_api_gateway_method.options_method.http_method
  status_code = aws_api_gateway_method_response.options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# tfsec:ignore:aws-api-gateway-enable-access-logging
# tfsec:ignore:aws-api-gateway-enable-tracing
resource "aws_api_gateway_stage" "production_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.portfolio_api.id
  stage_name    = "prod"
}

resource "aws_lambda_permission" "api_gateway_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_counter_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn = "${aws_api_gateway_rest_api.portfolio_api.execution_arn}/*/*"
}

resource "aws_api_gateway_resource" "metrics_resource" {
  rest_api_id = aws_api_gateway_rest_api.portfolio_api.id
  parent_id   = aws_api_gateway_rest_api.portfolio_api.root_resource_id
  path_part   = "metrics" 
}

# tfsec:ignore:aws-api-gateway-no-public-access
resource "aws_api_gateway_method" "metrics_method" {
  rest_api_id   = aws_api_gateway_rest_api.portfolio_api.id
  resource_id   = aws_api_gateway_resource.metrics_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "metrics_integration" {
  rest_api_id             = aws_api_gateway_rest_api.portfolio_api.id
  resource_id             = aws_api_gateway_resource.metrics_resource.id
  http_method             = aws_api_gateway_method.metrics_method.http_method
  integration_http_method = "POST" 
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.visitor_counter_lambda.invoke_arn
}

resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.portfolio_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.visitors_resource.id,
      aws_api_gateway_method.post_method.id,
      aws_api_gateway_integration.post_integration.id,
      aws_api_gateway_method.options_method.id,
      aws_api_gateway_integration.options_integration.id,
      aws_api_gateway_resource.metrics_resource.id, 
      aws_api_gateway_method.metrics_method.id,       
      aws_api_gateway_integration.metrics_integration.id 
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

output "api_invoke_url" {
  description = "The invoke URL for the visitor counter endpoint"
  value       = "${aws_api_gateway_stage.production_stage.invoke_url}/${aws_api_gateway_resource.visitors_resource.path_part}"
}