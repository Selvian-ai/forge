#!/bin/bash

# Package Lambda Function for Deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="email-ingestion.zip"
BUILD_DIR="build"
S3_BUCKET="your-lambda-deployment-bucket"  # Change this to your S3 bucket

echo "📦 Packaging Lambda function..."

# Clean up previous build
rm -rf "$BUILD_DIR"
rm -f "$PACKAGE_NAME"

# Create build directory
mkdir -p "$BUILD_DIR"

# Copy source code
echo "📋 Copying source code..."
cp "$SCRIPT_DIR/src/lambda_function.py" "$BUILD_DIR/"

# Install dependencies
echo "📚 Installing dependencies..."
pip install -r "$SCRIPT_DIR/src/requirements.txt" -t "$BUILD_DIR/"

# Create deployment package
echo "🗜️  Creating deployment package..."
cd "$BUILD_DIR"
zip -r "../$PACKAGE_NAME" .
cd ..

# Upload to S3 (optional)
if [ "$1" = "--upload" ]; then
    echo "☁️  Uploading to S3..."
    aws s3 cp "$PACKAGE_NAME" "s3://$S3_BUCKET/"
    echo "✅ Package uploaded to s3://$S3_BUCKET/$PACKAGE_NAME"
fi

# Clean up build directory
rm -rf "$BUILD_DIR"

echo "✅ Packaging complete!"
echo "📦 Package: $PACKAGE_NAME"
echo "📏 Size: $(du -h "$PACKAGE_NAME" | cut -f1)"

if [ "$1" != "--upload" ]; then
    echo ""
    echo "To upload to S3, run: $0 --upload"
    echo "Make sure to update the S3_BUCKET variable in this script first."
fi 