#!/bin/bash

# GCP Pub/Sub Setup Script
# Creates Pub/Sub topic and configures Gmail permissions

set -e

PROJECT_ID="forge-home-prod"
TOPIC_NAME="gmail-alerts"
GMAIL_PUBLISHER_SA="gmail-api-push@system.gserviceaccount.com"

echo "🔧 Setting up Pub/Sub for project: $PROJECT_ID"

# Set the project
gcloud config set project "$PROJECT_ID"

# Create the topic if it doesn't exist
echo "📢 Creating Pub/Sub topic: $TOPIC_NAME"
if gcloud pubsub topics describe "$TOPIC_NAME" >/dev/null 2>&1; then
    echo "✅ Topic $TOPIC_NAME already exists"
else
    gcloud pubsub topics create "$TOPIC_NAME"
    echo "✅ Topic $TOPIC_NAME created successfully"
fi

# Grant Gmail's publisher service account permission
echo "🔐 Granting Gmail publisher permissions..."
gcloud pubsub topics add-iam-policy-binding "$TOPIC_NAME" \
    --member="serviceAccount:$GMAIL_PUBLISHER_SA" \
    --role="roles/pubsub.publisher"

echo "✅ Gmail publisher permissions granted"

echo "✅ Pub/Sub setup complete!"
echo "Topic: $TOPIC_NAME"
echo "Gmail Publisher SA: $GMAIL_PUBLISHER_SA" 