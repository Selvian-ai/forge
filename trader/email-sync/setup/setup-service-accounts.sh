#!/bin/bash

# GCP Service Account Setup Script
# Creates service accounts for authentication

set -e

PROJECT_ID="forge-home-prod"
SA_NAME="gmail-push-auth"
SA_DISPLAY_NAME="Gmail Push Authentication Service Account"

echo "🔧 Setting up service accounts for project: $PROJECT_ID"

# Set the project
gcloud config set project "$PROJECT_ID"

# Create service account if it doesn't exist
echo "👤 Creating service account: $SA_NAME"
if gcloud iam service-accounts describe "$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" >/dev/null 2>&1; then
    echo "✅ Service account $SA_NAME already exists"
else
    gcloud iam service-accounts create "$SA_NAME" \
        --display-name="$SA_DISPLAY_NAME"
    echo "✅ Service account $SA_NAME created successfully"
fi

# Get service account email
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
echo "📧 Service account email: $SA_EMAIL"

# Create and download a key (optional - for manual testing)
echo "🔑 Creating service account key..."
KEY_FILE="gmail-push-auth-key.json"
if [ ! -f "$KEY_FILE" ]; then
    gcloud iam service-accounts keys create "$KEY_FILE" \
        --iam-account="$SA_EMAIL"
    echo "✅ Service account key created: $KEY_FILE"
    echo "⚠️  Keep this key secure and don't commit it to version control!"
else
    echo "✅ Service account key already exists: $KEY_FILE"
fi

echo "✅ Service account setup complete!"
echo "Service Account: $SA_EMAIL"
echo "Key File: $KEY_FILE" 