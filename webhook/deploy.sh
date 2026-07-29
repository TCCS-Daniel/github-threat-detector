#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEBHOOK="$(cd "$(dirname "$0")" && pwd)"

set -a
# shellcheck source=/dev/null
source "$ROOT/deploy/aws.env"
set +a

export AWS_PROFILE AWS_REGION

SECRETS="$WEBHOOK/.deploy.secrets.json"
ENV_FILE="$ROOT/.env"
if [[ ! -f "$SECRETS" ]]; then
  echo "Missing $SECRETS (DBPassword, WebhookSecret)" >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE (GITHUB_TOKEN)" >&2
  exit 1
fi

DB_PASSWORD="$(python3 -c "import json; print(json.load(open('$SECRETS'))['DBPassword'])")"
WEBHOOK_SECRET="$(python3 -c "import json; print(json.load(open('$SECRETS'))['WebhookSecret'])")"
GITHUB_TOKEN="$(python3 -c "
for line in open('$ENV_FILE'):
    if line.startswith('GITHUB_TOKEN='):
        print(line.split('=', 1)[1].strip())
        break
")"
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN missing from $ENV_FILE" >&2
  exit 1
fi

VPC_ID="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Parameters[?ParameterKey=='VpcId'].ParameterValue | [0]" --output text)"
SUBNET_IDS="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Parameters[?ParameterKey=='SubnetIds'].ParameterValue | [0]" --output text)"

echo "Deploying stack=$STACK_NAME profile=$AWS_PROFILE region=$AWS_REGION"

cd "$WEBHOOK"
sam build --use-container
sam deploy \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --capabilities CAPABILITY_IAM \
  --resolve-s3 \
  --resolve-image-repos \
  --no-confirm-changeset \
  --parameter-overrides \
    "VpcId=$VPC_ID" \
    "SubnetIds=$SUBNET_IDS" \
    "DBPassword=$DB_PASSWORD" \
    "WebhookSecret=$WEBHOOK_SECRET" \
    "GitHubToken=$GITHUB_TOKEN" \
    "TargetOrgs=${TARGET_ORGS:-supplychain-labs}" \
    "ParameterKey=TargetRepoPrefix,ParameterValue=" \
    "ParameterKey=TargetRepos,ParameterValue="

echo "Ensuring TargetRepos is empty (org discovery only)..."
if ! aws cloudformation update-stack \
  --stack-name "$STACK_NAME" \
  --use-previous-template \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=TargetOrgs,UsePreviousValue=true \
    ParameterKey=TargetRepoPrefix,UsePreviousValue=true \
    ParameterKey=TargetRepos,ParameterValue="" \
    ParameterKey=DBPassword,UsePreviousValue=true \
    ParameterKey=VpcId,UsePreviousValue=true \
    ParameterKey=DBName,UsePreviousValue=true \
    ParameterKey=SnapshotSchedule,UsePreviousValue=true \
    ParameterKey=ForensicsSchedule,UsePreviousValue=true \
    ParameterKey=SubnetIds,UsePreviousValue=true \
    ParameterKey=GitHubToken,UsePreviousValue=true \
    ParameterKey=DBPort,UsePreviousValue=true \
    ParameterKey=WebhookSecret,UsePreviousValue=true \
    ParameterKey=DBUsername,UsePreviousValue=true 2>&1 | tee /tmp/cfn-update.log; then
  grep -q "No updates are to be performed" /tmp/cfn-update.log || exit 1
else
  aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME"
fi

echo "Deploy complete."
