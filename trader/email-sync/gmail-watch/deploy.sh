#!/bin/bash

# Deploy Gmail Watch Function to Google Cloud Functions

set -e

PROJECT_ID="trade-alerts"
FUNCTION_NAME="gmail-watch-renewal"
REGION="us-central1"
RUNTIME="python39"
ENTRY_POINT="main"
MEMORY="256MB"
TIMEOUT="60s"

echo "🚀 Deploying Gmail Watch Function to Google Cloud Functions..."

# Set the project
gcloud config set project "$PROJECT_ID"

# Create requirements.txt if it doesn't exist
if [ ! -f "requirements.txt" ]; then
    echo "❌ requirements.txt not found. Please create it first."
    exit 1
fi

# Deploy the function
echo "📦 Deploying function: $FUNCTION_NAME"
gcloud functions deploy "$FUNCTION_NAME" \
    --runtime="$RUNTIME" \
    --trigger-http \
    --entry-point="$ENTRY_POINT" \
    --memory="$MEMORY" \
    --timeout="$TIMEOUT" \
    --region="$REGION" \
    --allow-unauthenticated

echo "✅ Function deployed successfully!"

# Get the function URL
FUNCTION_URL=$(gcloud functions describe "$FUNCTION_NAME" --region="$REGION" --format="value(httpsTrigger.url)")

echo ""
echo "📋 Function Details:"
echo "Name: $FUNCTION_NAME"
echo "URL: $FUNCTION_URL"
echo "Region: $REGION"
echo ""
echo "🔗 To test the function:"
echo "curl $FUNCTION_URL"
echo ""
echo "📅 To set up daily execution, create a Cloud Scheduler job:"
echo "gcloud scheduler jobs create http gmail-watch-daily \\"
echo "  --schedule='0 12 * * *' \\"
echo "  --uri='$FUNCTION_URL' \\"
echo "  --http-method=POST" 