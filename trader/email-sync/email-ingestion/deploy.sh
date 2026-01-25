#!/bin/bash

# Deploy Email Ingestion Infrastructure to AWS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME="email-ingestion"
ENVIRONMENT="${1:-prod}"
REGION="${2:-us-east-1}"
S3_BUCKET="${3:-your-lambda-deployment-bucket}"  # Change this to your S3 bucket

echo "🚀 Deploying Email Ingestion Infrastructure to AWS"
echo "=================================================="
echo "Stack Name: $STACK_NAME"
echo "Environment: $ENVIRONMENT"
echo "Region: $REGION"
echo "S3 Bucket: $S3_BUCKET"
echo ""

# Check if AWS CLI is configured
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS CLI not configured. Please run 'aws configure' first."
    exit 1
fi

# Package Lambda function
echo "📦 Packaging Lambda function..."
bash "$SCRIPT_DIR/package.sh" --upload

# Deploy CloudFormation stack
echo "☁️  Deploying CloudFormation stack..."
aws cloudformation deploy \
    --template-file "$SCRIPT_DIR/infra/template.yaml" \
    --stack-name "$STACK_NAME" \
    --parameter-overrides \
        Environment="$ENVIRONMENT" \
        LambdaCodeBucket="$S3_BUCKET" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION"

# Get stack outputs
echo "📋 Getting stack outputs..."
API_GATEWAY_URL=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`ApiGatewayUrl`].OutputValue' \
    --output text)

DYNAMODB_TABLE=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`DynamoDBTableName`].OutputValue' \
    --output text)

echo ""
echo "✅ Deployment complete!"
echo "=================================================="
echo "📡 API Gateway URL: $API_GATEWAY_URL"
echo "🗄️  DynamoDB Table: $DYNAMODB_TABLE"
echo ""
echo "🔗 Next steps:"
echo "1. Configure Pub/Sub push subscription to point to: $API_GATEWAY_URL"
echo "2. Test the endpoint: curl -X POST $API_GATEWAY_URL"
echo "3. Monitor CloudWatch logs for the Lambda function" 