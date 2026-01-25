#!/bin/bash

# Master GCP Setup Script
# Runs all setup scripts in the correct order

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Starting GCP setup for forge-home-prod project..."
echo "=================================================="

# Run setup scripts in order
echo ""
echo "1. Creating GCP project..."
bash "$SCRIPT_DIR/create-project.sh"

echo ""
echo "2. Enabling required APIs..."
bash "$SCRIPT_DIR/enable-apis.sh"

echo ""
echo "3. Setting up Pub/Sub..."
bash "$SCRIPT_DIR/create-pubsub.sh"

echo ""
echo "4. Creating service accounts..."
bash "$SCRIPT_DIR/setup-service-accounts.sh"

echo ""
echo "=================================================="
echo "✅ GCP setup complete!"
echo ""
echo "Next steps:"
echo "1. Deploy the Gmail watch function: cd ../gmail-watch && ./deploy.sh"
echo "2. Deploy AWS infrastructure: cd ../email-ingestion && ./deploy.sh"
echo "3. Configure Pub/Sub push subscription to point to your AWS API Gateway" 