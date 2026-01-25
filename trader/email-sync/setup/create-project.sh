#!/bin/bash

# GCP Project Setup Script
# Creates the forge-home-prod project if it doesn't exist

set -e

PROJECT_ID="forge-home-prod"
PROJECT_NAME="Forge Home Prod"

echo "🔧 Setting up GCP project: $PROJECT_ID"

# Check if project already exists
if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    echo "✅ Project $PROJECT_ID already exists"
else
    echo "📦 Creating project $PROJECT_ID..."
    gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME"
    echo "✅ Project $PROJECT_ID created successfully"
fi

# Set the project as the default
echo "🎯 Setting $PROJECT_ID as default project..."
gcloud config set project "$PROJECT_ID"

echo "✅ Project setup complete!"
echo "Project ID: $PROJECT_ID"
echo "Project Name: $PROJECT_NAME" 