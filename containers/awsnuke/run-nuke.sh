#!/bin/bash

# Disable AWS CLI pager and interactive prompts
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# Configuration from environment variables with defaults
MAX_JOBS=${MAX_JOBS:-12}
REFRESH_THRESHOLD=${REFRESH_THRESHOLD:-300}

# Parse EXCLUDE_BUCKET_PREFIXES from comma-delimited environment variable
# If not provided or empty, all buckets will be deleted (no exclusions)
if [ -z "$EXCLUDE_BUCKET_PREFIXES" ]; then
  EXCLUDE_PREFIXES=()
  echo "No bucket exclusions configured - all buckets will be deleted"
else
  IFS=',' read -ra EXCLUDE_PREFIXES <<< "$EXCLUDE_BUCKET_PREFIXES"
  echo "Excluding buckets with prefixes: ${EXCLUDE_PREFIXES[*]}"
fi

# Check if REGIONS is provided
if [ -z "$REGIONS" ]; then
  echo "Error: REGIONS environment variable is not set."
  exit 1
fi

# Parse REGIONS from comma-delimited environment variable
IFS=',' read -ra REGIONS <<< "$REGIONS"

echo "Using regions: ${REGIONS[*]}"

# Check if ACCOUNT_ID is provided
if [ -z "$ACCOUNT_ID" ]; then
  echo "Error: ACCOUNT_ID environment variable is not set."
  exit 1
fi

if [ -z "$NUKE_ROLE_NAME" ]; then
  echo "Error: NUKE_ROLE_NAME environment variable is not set."
  exit 1
fi

# Assume the role in the target account
ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$NUKE_ROLE_NAME"
SESSION_NAME="AwsNukeSession"

# Restore the original execution role session
restore_execution_role() {
  echo "Restoring original execution role session..."
  export AWS_ACCESS_KEY_ID=$ECS_AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$ECS_AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN=$ECS_AWS_SESSION_TOKEN
  echo "Original execution role credentials restored."
}

assume_role() {
  echo "Assuming role: $ROLE_ARN"
  CREDS_JSON=$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name "$SESSION_NAME")
  if [[ $? -ne 0 ]]; then
    echo "Failed to assume role $ROLE_ARN"
    exit 1
  fi

  export AWS_ACCESS_KEY_ID=$(echo "$CREDS_JSON" | jq -r '.Credentials.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS_JSON" | jq -r '.Credentials.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$CREDS_JSON" | jq -r '.Credentials.SessionToken')

  # Extract session expiration time and convert to Unix timestamp
  local expiration_iso=$(echo "$CREDS_JSON" | jq -r '.Credentials.Expiration')
  EXPIRATION_TIMESTAMP=$(date -d "$expiration_iso" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${expiration_iso%.*}" +%s)

  echo "Role assumed successfully. Credentials valid until $(date -d "@$EXPIRATION_TIMESTAMP")"
}

refresh_credentials_if_needed() {
  # Skip if EXPIRATION_TIMESTAMP is not set
  if [[ -z "$EXPIRATION_TIMESTAMP" ]]; then
    return
  fi

  CURRENT_TIMESTAMP=$(date +%s)
  TIME_LEFT=$((EXPIRATION_TIMESTAMP - CURRENT_TIMESTAMP))

  if [[ $TIME_LEFT -le $REFRESH_THRESHOLD ]]; then
    echo "Refreshing credentials (time left: $TIME_LEFT seconds)..."
    assume_role
  fi
}

# Function to delete all versions and delete markers in a bucket using batch operations
delete_bucket_contents() {
  local bucket="$1"
  echo "Deleting all versions and delete markers in bucket: $bucket"

  local next_token=""
  local batch_size=1000

  while true; do
    refresh_credentials_if_needed

    # Build the list-object-versions command
    local cmd="aws s3api list-object-versions --bucket $bucket --max-items $batch_size"
    if [[ -n "$next_token" ]]; then
      cmd="$cmd --starting-token $next_token"
    fi

    # Get objects and delete markers in one call
    local result=$(eval "$cmd --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers: DeleteMarkers[].{Key:Key,VersionId:VersionId}, NextToken: NextToken}' --output json")

    if [[ $? -ne 0 ]]; then
      echo "Failed to list object versions for bucket: $bucket"
      return 1
    fi

    # Extract objects, delete markers, and next token
    local objects=$(echo "$result" | jq -c '.Objects // []')
    local delete_markers=$(echo "$result" | jq -c '.DeleteMarkers // []')
    next_token=$(echo "$result" | jq -r '.NextToken // empty')

    # Combine objects and delete markers for batch deletion
    local all_objects=$(echo "$objects $delete_markers" | jq -s 'add')

    if [[ $(echo "$all_objects" | jq 'length') -gt 0 ]]; then
      echo "Batch deleting $(echo "$all_objects" | jq 'length') objects/versions..."

      # Create delete request
      local delete_request=$(echo "$all_objects" | jq '{Objects: .}')

      # Perform batch delete
      echo "$delete_request" | aws s3api delete-objects --bucket "$bucket" --delete file:///dev/stdin

      if [[ $? -ne 0 ]]; then
        echo "Failed to batch delete objects in bucket: $bucket"
        return 1
      fi
    fi

    # Break if no more objects
    if [[ -z "$next_token" ]]; then
      break
    fi
  done

  echo "All objects and versions deleted from bucket: $bucket"
}

# Function to delete a bucket
delete_bucket() {
  local bucket="$1"
  echo "Deleting bucket: $bucket"

  # Delete bucket contents first
  delete_bucket_contents "$bucket"
  if [[ $? -ne 0 ]]; then
    echo "Failed to delete contents of bucket: $bucket"
    return 1
  fi

  # Attempt to delete the bucket
  aws s3api delete-bucket --bucket "$bucket"
  if [[ $? -ne 0 ]]; then
    echo "Failed to delete bucket: $bucket"
    return 1
  fi

  echo "Successfully deleted bucket: $bucket"
}

############################## START ################################

# Store the execution role credentials to be used later by aws-nuke
export ECS_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
export ECS_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
export ECS_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

# Fetch the list of protected accounts from the SSM Parameter Store
SSM_PARAM_NAME="/autonuke/blocklist"
ACCOUNT_BLOCKLIST=$(aws ssm get-parameter --name "$SSM_PARAM_NAME" --query "Parameter.Value" --output text 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "SSM parameter '$SSM_PARAM_NAME' not found. Exiting."
  whoAmI=$(aws sts get-caller-identity)
  region=$(aws configure get region)
  echo "Current user: $whoAmI, current region: $region"
  exit 1
fi

echo "Fetched account blocklist: $ACCOUNT_BLOCKLIST"

if [ -z "$ACCOUNT_BLOCKLIST" ]; then
  echo "Account list is empty. You need to configure the parameter $SSM_PARAM_NAME with at least one account ID."
  exit 1
fi

# Check if the target account ID can be targeted for clean-up
if echo "$ACCOUNT_BLOCKLIST" | grep -qw "$ACCOUNT_ID"; then
  echo "Account $ACCOUNT_ID is protected and cannot be nuked. Exiting."
  exit 0
fi

# Assume role in the target account
assume_role

###### Start pre-nuke cleanup ######

# aws-nuke cannot handle S3 object deletions efficiently. It takes a long time and occasionally times out for large buckets.
# S3 buckets are deleted by this script recursively, using high batch size and multiple threads.

# List all S3 buckets and delete them with concurrency
while read -r bucket; do
  refresh_credentials_if_needed

  # Check if bucket matches any excluded prefix
  skip_bucket=false
  for prefix in "${EXCLUDE_PREFIXES[@]}"; do
    if [[ $bucket =~ $prefix ]]; then
      skip_bucket=true
      break
    fi
  done

  if [ "$skip_bucket" = true ]; then
    echo "Skip bucket: $bucket"
  else
      delete_bucket "$bucket" &
      while [[ $(jobs -r | wc -l) -ge $MAX_JOBS ]]; do sleep 1; done
  fi
done < <(aws s3 ls | cut -d" " -f 3)

wait
echo "All buckets have been processed."

# Disable deletion protection for DynamoDB tables. aws-nuke cannot handle this natively.
# Recovery points for backup vaults also cause issues. Delete them before invoking aws-nuke.
for REGION in "${REGIONS[@]}"; do
  echo "=== Processing region: $REGION ==="
  # --- Disable DynamoDB table deletion protection ---
  tables=$(aws dynamodb list-tables \
    --region "$REGION" \
    --query 'TableNames[]' \
    --output text || true)

  if [ -n "$tables" ]; then
    for table in $tables; do
      echo "Disabling deletion protection for DynamoDB table: $table"
      aws dynamodb update-table \
        --table-name "$table" \
        --no-deletion-protection-enabled \
        --region "$REGION" \
        || echo "  -> failed for $table (continuing)"
    done
  else
    echo "No DynamoDB tables found in $REGION"
  fi

  # Delete recovery points.
  for vault in $(aws backup list-backup-vaults --region "$REGION" --query 'BackupVaultList[].BackupVaultName' --output text); do
    echo "Cleaning vault: $vault"

    for arn in $(aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "$vault" \
        --region "$REGION" \
        --query 'RecoveryPoints[].RecoveryPointArn' \
        --output text); do

      echo "  Deleting recovery point: $arn"
      aws backup delete-recovery-point \
        --backup-vault-name "$vault" \
        --recovery-point-arn "$arn" \
        --region "$REGION" || true
    done
  done
done

# Generate the aws-nuke configuration file from the template by replacing all placeholders.
sed "s/__ACCOUNT_ID__/${ACCOUNT_ID}/g" /root/config.yaml.template > /tmp/nuke.yaml

# Convert the account list into the required blocklist format
BLOCKLIST=$(printf "  - %s\n" $(echo "$ACCOUNT_BLOCKLIST" | tr ',' ' '))

# Use a temporary marker to avoid escaping issues
MARKER="__BLOCKLISTED_ACCOUNTS__"

# Replace the marker in the config template with the blocklist
sed "/$MARKER/r /dev/stdin" /tmp/nuke.yaml <<< "$BLOCKLIST" | sed "/$MARKER/d" > /tmp/nuke-config.yaml

# Inject regions into the config from the REGIONS env var
REGION_MARKER="__REGIONS__"
REGION_LIST=$(printf "  - %s\n" "${REGIONS[@]}")
echo "Regions: $REGION_LIST"
sed "/$REGION_MARKER/r /dev/stdin" /tmp/nuke-config.yaml <<< "$REGION_LIST" | sed "/$REGION_MARKER/d" > /tmp/nuke-config.yaml.tmp && mv /tmp/nuke-config.yaml.tmp /tmp/nuke-config.yaml

# Restore the ECS execution role credentials to allow aws-nuke assume the cross-account role.
# This way it can refresh the credentials whenever needed.
restore_execution_role

# Run aws-nuke with the generated configuration
/usr/local/bin/aws-nuke nuke -c /tmp/nuke-config.yaml --no-prompt --no-alias-check --no-dry-run --assume-role-arn $ROLE_ARN --assume-role-session-name aws-nuke
nuke_result=$?

if [ $nuke_result -eq 0 ]; then
  echo "aws-nuke ran successfully."
else
  echo "aws-nuke failed with exit code $nuke_result."
  exit $nuke_result
fi
