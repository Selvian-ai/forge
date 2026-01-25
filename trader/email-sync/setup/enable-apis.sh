#!/bin/bash

# GCP API Enablement Script
# Enables required APIs for the forge-home-prod project

set -e

PROJECT_ID="forge-home-prod"
APIS=(
    "gmail.googleapis.com"
    "pubsub.googleapis.com"
    "secretmanager.googleapis.com"
)

echo "🔧 Enabling APIs for project: $PROJECT_ID"

# Set the project
gcloud config set project "$PROJECT_ID"

# Enable each API
for api in "${APIS[@]}"; do
    echo "🔌 Enabling $api..."
    
    # Check if API is already enabled
    if gcloud services list --enabled --filter="name:$api" --format="value(name)" | grep -q "$api"; then
        echo "✅ $api is already enabled"
    else
        gcloud services enable "$api"
        echo "✅ $api enabled successfully"
    fi
done

echo "✅ All APIs enabled successfully!" 