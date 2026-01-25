"""
Email Ingestion Lambda Function

Handles incoming Gmail notifications from Google Cloud Pub/Sub.
Verifies JWT tokens and processes email content.
"""

import json
import base64
import boto3
import jwt
import requests
import uuid
from datetime import datetime
from googleapiclient.discovery import build
from google.oauth2.credentials import Credentials
from botocore.exceptions import ClientError

# Configuration
GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v1/certs"
SECRET_NAME = "gmail/api/credentials"
REGION = "us-east-1"
DYNAMODB_TABLE = "trade-alerts"

def verify_jwt(token):
    """Verify the JWT token from Google."""
    try:
        header = jwt.get_unverified_header(token)
        certs = requests.get(GOOGLE_CERTS_URL).json()
        payload = jwt.decode(
            token, 
            certs[header['kid']], 
            audience=event['requestContext']['domainName'],  # API Gateway domain
            issuer='https://accounts.google.com'
        )
        return payload
    except Exception as e:
        print(f"❌ JWT verification failed: {e}")
        raise

def get_credentials_from_secrets_manager():
    """Retrieve Gmail API credentials from AWS Secrets Manager."""
    try:
        sm = boto3.client("secretsmanager", region_name=REGION)
        response = sm.get_secret_value(SecretId=SECRET_NAME)
        cred_json = json.loads(response['SecretString'])
        return Credentials.from_authorized_user_info(cred_json)
    except ClientError as e:
        print(f"❌ Failed to retrieve credentials: {e}")
        raise

def fetch_email_content(message_id):
    """Fetch the full email content from Gmail API."""
    try:
        creds = get_credentials_from_secrets_manager()
        service = build('gmail', 'v1', credentials=creds)
        
        email = service.users().messages().get(
            userId='me', 
            id=message_id, 
            format='full'
        ).execute()
        
        return email
    except Exception as e:
        print(f"❌ Failed to fetch email: {e}")
        raise

def classify_email(email_data):
    """Classify the email content to determine if it's a trade alert."""
    # TODO: Implement email classification logic
    # This could use regex patterns, ML models, or LLM calls
    
    # For now, return a basic classification
    return {
        "type": "UNKNOWN",
        "ticker": None,
        "confidence": 0.0
    }

def store_alert_in_dynamodb(alert_data):
    """Store the alert in DynamoDB."""
    try:
        dynamodb = boto3.resource('dynamodb', region_name=REGION)
        table = dynamodb.Table(DYNAMODB_TABLE)
        
        table.put_item(Item=alert_data)
        print(f"✅ Alert stored in DynamoDB: {alert_data['id']}")
        
    except Exception as e:
        print(f"❌ Failed to store alert: {e}")
        raise

def lambda_handler(event, context):
    """Main Lambda handler function."""
    print("🚀 Email ingestion triggered")
    
    try:
        # Verify JWT token
        auth_header = event.get('headers', {}).get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return {
                'statusCode': 401,
                'body': json.dumps({'error': 'Missing or invalid Authorization header'})
            }
        
        token = auth_header.split(' ')[1]
        verify_jwt(token)
        
        # Parse the Pub/Sub message
        body = json.loads(event['body'])
        message_data = base64.b64decode(body['message']['data']).decode('utf-8')
        message = json.loads(message_data)
        
        print(f"📧 Processing message: {message.get('historyId', 'unknown')}")
        
        # Extract message ID from the notification
        # The exact field depends on the watch configuration
        message_id = message.get('messageId') or message.get('id')
        if not message_id:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'No message ID found in notification'})
            }
        
        # Fetch the full email content
        email_data = fetch_email_content(message_id)
        
        # Classify the email
        classification = classify_email(email_data)
        
        # Create alert record
        alert_data = {
            "id": str(uuid.uuid4()),
            "received_at": datetime.utcnow().isoformat() + "Z",
            "message_id": message_id,
            "type": classification["type"],
            "ticker": classification["ticker"],
            "confidence": classification["confidence"],
            "raw_body": email_data.get('snippet', ''),
            "processed": False,
            "email_data": email_data  # Store full email data for processing
        }
        
        # Store in DynamoDB
        store_alert_in_dynamodb(alert_data)
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Email processed successfully',
                'alert_id': alert_data['id']
            })
        }
        
    except Exception as e:
        print(f"❌ Error processing email: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        } 