# Trader

## Gmail API Credentials Setup

### Overview

The `trade-alerts-email-fetcher/setup-secrets.py` script is used to set up and refresh Gmail API OAuth credentials for the email fetcher service.

### Purpose

This script runs **ad-hoc** when we need to refresh the OAuth token for the Gmail API integration. It handles the complete OAuth flow and securely stores the credentials in AWS Secrets Manager.

### How it works

1. **1Password Integration**: The script authenticates with 1Password CLI and retrieves the Google service account client secret file from the `Machines` vault
2. **OAuth Flow**: It initiates the Google OAuth flow, opening a browser for user authentication
3. **Token Storage**: After successful authentication, it stores the credentials (client ID, client secret, and refresh token) in AWS Secrets Manager under the key `gmail/api/credentials`
4. **Security**: All credentials are encrypted using AWS KMS before storage

### Google Project Details

- **Project**: `forge-home-prod`
- **Service Account**: The OAuth app is registered under this Google Cloud project
- **Scopes**: `https://www.googleapis.com/auth/gmail.readonly` (read-only access to Gmail)

### Prerequisites

- 1Password CLI installed and configured
- AWS credentials configured with access to Secrets Manager
- Access to the Google OAuth app (must be added as a test user if not verified)

### Usage

```bash
cd trader
poetry run python trade-alerts-email-fetcher/setup-secrets.py
```

The script will:
1. Prompt for your 1Password password
2. Open a browser for Google OAuth authentication
3. Store the credentials in AWS Secrets Manager

### When to run

Run this script when:
- Setting up the email fetcher for the first time
- The OAuth refresh token expires (typically after 6 months)
- You need to update the service account credentials

## Real-Time Gmail Pipeline

### Architecture Overview

```
Gmail → Pub/Sub → AWS API Gateway → Lambda → DynamoDB
```

This real-time pipeline uses Gmail's native push notifications through Google Cloud Pub/Sub to achieve sub-second email ingestion latency.

### Pipeline Components

#### 0. GCP Setup (One-time)

```bash
# Create project
gcloud projects create trade-alerts

# Enable APIs
gcloud services enable gmail.googleapis.com pubsub.googleapis.com

# Create Pub/Sub topic
gcloud pubsub topics create gmail-alerts

# Grant Gmail's publisher service account permission
gcloud pubsub topics add-iam-policy-binding gmail-alerts \
  --member=serviceAccount:gmail-api-push@system.gserviceaccount.com \
  --role=roles/pubsub.publisher

# Create service account for auth
gcloud iam service-accounts create gmail-push-auth

# Get service account email
gcloud iam service-accounts describe gmail-push-auth
```

#### 1. Pub/Sub Push Subscription

```bash
API_URL="https://abc123.execute-api.us-east-1.amazonaws.com/prod/gmail"

gcloud pubsub subscriptions create gmail-alerts-to-aws \
  --topic gmail-alerts \
  --push-endpoint="$API_URL" \
  --push-auth-service-account=gmail-push-auth@trade-alerts.iam.gserviceaccount.com \
  --push-auth-token-audience="$API_URL"
```

#### 2. Gmail Watch Registration

Run daily to maintain the watch (Gmail expires after 7 days):

```python
from googleapiclient.discovery import build
from google.oauth2.credentials import Credentials

creds = Credentials.from_authorized_user_info(secret_json)
service = build('gmail', 'v1', credentials=creds)

watch = service.users().watch(
    userId='me',
    body={
      "labelIds": ["INBOX"],
      "topicName": "projects/trade-alerts/topics/gmail-alerts",
      "labelFilterAction": "include"
    }
).execute()

print("expires:", watch["expiration"])
```

#### 3. AWS Ingress (API Gateway + Lambda)

The Lambda function verifies the JWT from Google and processes incoming emails:

```python
import json, base64, boto3, jwt, requests
from googleapiclient.discovery import build
from google.oauth2.credentials import Credentials

GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v1/certs"
AUD = "https://abc123.execute-api.us-east-1.amazonaws.com/prod/gmail"

def verify_jwt(token):
    header = jwt.get_unverified_header(token)
    certs = requests.get(GOOGLE_CERTS_URL).json()
    payload = jwt.decode(token, certs[header['kid']], audience=AUD, issuer='https://accounts.google.com')
    return payload

def handler(event, _ctx):
    token = event['headers']['Authorization'].split()[1]
    verify_jwt(token)
    msg = json.loads(base64.b64decode(event['body']))
    message_id = msg['message']['data']

    # Fetch full email using stored credentials
    sms = boto3.client('secretsmanager')
    cred_json = json.loads(sms.get_secret_value(SecretId='gmail/api/credentials')['SecretString'])
    creds = Credentials(**cred_json, token=None)
    svc = build('gmail', 'v1', credentials=creds)
    email = svc.users().messages().get(userId='me', id=message_id, format='full').execute()

    # Process and store in DynamoDB
    # ...
```

#### 4. Alert Classification & Storage

Process emails and store in DynamoDB:

```json
{
  "id": "<uuid>",
  "received_at": "2025-07-26T14:00:12Z",
  "type": "BUY",
  "ticker": "NVDA",
  "raw_body": "...",
  "processed": false
}
```

#### 5. Watch Renewal Lambda

Daily EventBridge rule to renew Gmail watch:

```python
def renew_watch_handler(event, _):
    creds = get_creds_from_sm()
    build('gmail','v1',credentials=creds).users().watch(
        userId='me',
        body={"labelIds":["INBOX"], "topicName":"projects/trade-alerts/topics/gmail-alerts"}
    ).execute()
```

### Performance Benefits

- **Real-time**: Gmail publishes to Pub/Sub immediately when messages arrive
- **Low latency**: Total ingestion delay is typically 1-3 seconds
- **No polling**: Eliminates SMTP hops and SES virus scanning delays
- **Reliable**: Pub/Sub provides guaranteed delivery with retries

### Security

- JWT verification ensures requests come from Google
- AWS KMS encryption for stored credentials
- IAM roles for service-to-service authentication
- No API keys exposed in code
