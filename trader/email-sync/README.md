# Email Sync

Real-time Gmail → AWS pipeline for trade alert processing.

## Project Structure

```
email-sync/
├── setup/                 # GCP one-time setup scripts
│   ├── create-project.sh
│   ├── enable-apis.sh
│   ├── create-pubsub.sh
│   └── setup-service-accounts.sh
├── gmail-watch/           # Gmail watch registration
│   ├── watch.py           # Python script to register Gmail watch
│   └── deploy.sh          # Deploy to Google Cloud Functions
├── email-ingestion/       # AWS email processing
│   ├── src/               # Lambda source code
│   ├── infra/             # CloudFormation templates
│   ├── package.sh         # Package Lambda for deployment
│   └── deploy.sh          # Deploy to AWS
└── README.md              # This file
```

## Components

### 1. Setup (`setup/`)
One-time GCP infrastructure setup scripts. Each script checks if resources exist before creating them.

- **setup-service-accounts.sh**: Creates the `gmail-push-auth` service account for Pub/Sub push authentication

### 2. Gmail Watch (`gmail-watch/`)
- **watch.py**: Registers Gmail watch to monitor inbox for new emails
- **deploy.sh**: Deploys the watch script to Google Cloud Functions for daily execution

### 3. Email Ingestion (`email-ingestion/`)
- **src/**: Lambda function source code for processing incoming emails
- **infra/**: CloudFormation templates for API Gateway, Lambda, DynamoDB, etc.
- **package.sh**: Packages Lambda code and dependencies
- **deploy.sh**: Deploys infrastructure to AWS

## Workflow

1. Run setup scripts to create GCP resources
2. Store the generated `gmail-push-auth-key.json` in 1Password
3. Deploy Gmail watch to register email monitoring
4. Deploy AWS infrastructure for email processing
5. Configure Pub/Sub push subscription to point to AWS API Gateway
6. Monitor and maintain watch renewal

## Prerequisites

- Google Cloud CLI (`gcloud`) configured
- AWS CLI configured
- 1Password CLI for credential management
- Python 3.8+ with required dependencies

## Credential Management

### Gmail API OAuth Credentials
- **Stored in:** AWS Secrets Manager
- **Used by:** Lambda function (to fetch emails) and Gmail watch function
- **Setup:** Run `trade-alerts-email-fetcher/setup-secrets.py`

### Service Account Key
- **Stored in:** 1Password (after running setup-service-accounts.sh)
- **Used by:** Local scripts and CI/CD (optional)
- **Purpose:** Authenticate as the Pub/Sub service account for management tasks 