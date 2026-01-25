#!/usr/bin/env python3
"""
Gmail Watch Registration Script

Registers a watch on the Gmail inbox to monitor for new emails.
This script should be run daily to maintain the watch (Gmail expires after 7 days).
"""

import json
import os
import sys
from datetime import datetime, timedelta
from googleapiclient.discovery import build
from google.oauth2.credentials import Credentials
import boto3
from botocore.exceptions import ClientError

# Configuration
PROJECT_ID = "forge-home-prod"
TOPIC_NAME = f"projects/{PROJECT_ID}/topics/gmail-alerts"
AWS_SECRET_NAME = "gmail/api/credentials"
AWS_REGION = "us-east-1"
REGION = "us-central1"

def get_credentials_from_aws_secrets_manager():
    """Retrieve Gmail API credentials from AWS Secrets Manager."""
    try:
        sm = boto3.client("secretsmanager", region_name=AWS_REGION)
        response = sm.get_secret_value(SecretId=AWS_SECRET_NAME)
        cred_json = json.loads(response['SecretString'])
        return Credentials.from_authorized_user_info(cred_json)
    except ClientError as e:
        print(f"❌ Failed to retrieve credentials from AWS Secrets Manager: {e}")
        sys.exit(1)

def register_gmail_watch():
    """Register a watch on the Gmail inbox."""
    print("🔧 Setting up Gmail watch...")
    
    # Get credentials
    creds = get_credentials_from_aws_secrets_manager()
    
    # Build Gmail service
    service = build('gmail', 'v1', credentials=creds)
    
    # Register watch
    try:
        watch_request = {
            "labelIds": ["INBOX"],
            "topicName": TOPIC_NAME,
            "labelFilterAction": "include"
        }
        
        print(f"📧 Registering watch on INBOX...")
        print(f"📢 Topic: {TOPIC_NAME}")
        
        watch = service.users().watch(
            userId='me',
            body=watch_request
        ).execute()
        
        # Parse expiration time
        expiration_ms = int(watch["expiration"])
        expiration_dt = datetime.fromtimestamp(expiration_ms / 1000)
        
        print("✅ Gmail watch registered successfully!")
        print(f"⏰ Expires: {expiration_dt.strftime('%Y-%m-%d %H:%M:%S UTC')}")
        print(f"📅 Expires in: {expiration_dt - datetime.utcnow()}")
        
        return watch
        
    except Exception as e:
        print(f"❌ Failed to register Gmail watch: {e}")
        sys.exit(1)

def main():
    """Main function."""
    print("🚀 Gmail Watch Registration")
    print("=" * 40)
    
    # Register the watch
    watch = register_gmail_watch()
    
    print("\n✅ Setup complete!")
    print("\nNote: This watch will expire in 7 days.")
    print("Make sure to run this script daily to maintain the watch.")

if __name__ == "__main__":
    main() 