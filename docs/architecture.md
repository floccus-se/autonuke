## Automating AWS Account Cleanups with aws-nuke: A Production-Ready Solution

Managing AWS resources across multiple accounts becomes increasingly challenging as organizations scale. Ephemeral environments, proof-of-concept projects, and development sandboxes accumulate resources that often outlive their purpose, leading to unnecessary costs and security risks. Manual cleanup is time-consuming, error-prone, and doesn't scale.

**aws-nuke** is an open-source tool designed to remove all resources from an AWS account systematically. While powerful, running aws-nuke safely in a multi-account organization requires careful orchestration, guardrails, and automation. This solution provides a production-ready implementation that wraps aws-nuke in a secure, scalable architecture using AWS managed services.

### The Challenge

Organizations face several challenges when managing temporary AWS accounts:

- **Resource sprawl**: Developers create resources for testing and forget to clean them up
- **Cost accumulation**: Orphaned resources (EC2 instances, RDS databases, S3 buckets) generate ongoing charges
- **Security hygiene**: Stale resources increase the attack surface and compliance risks
- **Manual toil**: Cleaning accounts manually is tedious and risks missing resources or deleting critical infrastructure
- **Scale limitations**: Managing dozens or hundreds of accounts requires automation

### Prerequisites

Before deploying this solution, ensure you have:

**AWS Organization Setup:**
- An AWS Organization with multiple accounts (sandbox, development, or test accounts)
- Organization ID for restricting cross-account access
- Designated "management" or "tools" account to host the autonuke infrastructure

**Administrative Access:**
- Administrator-level permissions in the management account to deploy CloudFormation stacks
- Ability to create cross-account IAM roles in target accounts
- Access to create ECR repositories and push container images

**Infrastructure Requirements:**
- Existing VPC with at least one subnet that has internet access (for pulling aws-nuke binaries)
- AWS CLI configured with appropriate credentials
- Docker with buildx support for multi-architecture builds

**Knowledge Requirements:**
- Familiarity with AWS Step Functions, ECS Fargate, and CloudFormation
- Understanding of IAM roles and cross-account access patterns
- Basic knowledge of container operations and Docker

## Use Cases

This solution is designed for:

- **Ephemeral environments**: Automatically tear down short-lived accounts after workshops, training sessions, or time-limited POCs
- **Development sandboxes**: Reset developer accounts to a clean state on a regular schedule (e.g., weekly)
- **Account offboarding**: Safely decommission accounts when projects end or business units reorganize
- **Cost control**: Eliminate orphaned resources in non-production accounts to reduce cloud spend
- **Compliance hygiene**: Reset accounts to a known-clean baseline for security audits or compliance requirements

## Architecture Overview

The autonuke solution implements a robust, multi-layered architecture designed for safe and efficient AWS account cleanup operations. The system leverages AWS managed services to provide scalability, reliability, and comprehensive monitoring.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Management Account                           │
│                                                                     │
│  ┌──────────────┐         ┌─────────────────┐                       │
│  │ EventBridge  │────────▶│ Step Functions  │                       │
│  │ (Schedule)   │         │  State Machine  │                       │
│  └──────────────┘         └────────┬────────┘                       │
│                                    │                                │
│                                    ▼                                │
│                          ┌─────────────────┐                        │
│                          │  Protected      │                        │
│                          │  Accounts List  │                        │
│                          │  (SSM Param)    │                        │
│                          └─────────────────┘                        │
│                                    │                                │
│                                    │ Validate                       │
│                                    ▼                                │
│                          ┌─────────────────┐                        │
│                          │   ECS Fargate   │                        │
│  ┌──────────────┐        │   Task          │                        │
│  │     ECR      │───────▶│                 │                        │
│  │  Repository  │        │  ┌───────────┐  │                        │
│  └──────────────┘        │  │ aws-nuke  │  │                        │
│                          │  │ Container │  │                        │
│                          │  └───────────┘  │                        │
│                          └────────┬────────┘                        │
│                                   │                                 │
│                                   │ AssumeRole                      │
│                                   │                                 │
└───────────────────────────────────┼─────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          Target Account                             │
│                                                                     │
│                    ┌───────────────────────┐                        │
│                    │  NukeExecutionRole    │                        │
│                    │  (AdministratorAccess)│                        │
│                    └───────────┬───────────┘                        │
│                                │                                    │
│                                ▼                                    │
│                    ┌─────────────────────┐                          │
│                    │ Delete Resources:   │                          │
│                    │ • EC2 Instances     │                          │
│                    │ • S3 Buckets        │                          │
│                    │ • Lambda Functions  │                          │
│                    │ • RDS Databases     │                          │
│                    │ • VPCs, Subnets     │                          │
│                    │ • ... and more      │                          │
│                    └─────────────────────┘                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Core Components

**Infrastructure Layer**
- **ECS Fargate Cluster**: Provides serverless container execution with automatic scaling and resource management
- **ECR Repository**: Stores the custom aws-nuke container image with immutable tags for version control
- **VPC & Security Groups**: Ensures network isolation and controlled outbound access for the cleanup tasks

**Orchestration Layer**
- **Step Functions State Machine**: Central orchestrator that manages the entire cleanup workflow with built-in retry logic and error handling
- **Parameter Store**: Centralized configuration management for protected accounts and runtime parameters
- **CloudWatch Logs**: Comprehensive logging and monitoring for audit trails and troubleshooting

**Security & Access Layer**
- **Cross-Account IAM Roles**: Secure role-based access control for executing cleanup operations in target accounts
- **Organization-Level Permissions**: Ensures cleanup operations are restricted to accounts within the same AWS Organization
- **Protected Account Lists**: Prevents accidental cleanup of critical production or shared service accounts

**Execution Layer**
- **Containerized aws-nuke**: Alpine-based image that dynamically fetches the latest aws-nuke binary at build time
- **Pre-cleanup Optimizations**: Custom scripts for efficient S3 bucket deletion and DynamoDB protection removal
- **Resource Scaling**: Automatic CPU/memory scaling on out-of-memory errors to handle large cleanup operations

### Workflow

The system follows a multi-stage workflow designed for reliability and safety:

1. **Initialization**: Validates input parameters (account ID) and sets up execution context
2. **Protection Check**: Queries SSM Parameter Store and verifies the target account is not in the protected accounts list
3. **Role Assumption**: Securely assumes the NukeExecutionRole in the target account with credential refresh capabilities
4. **Pre-cleanup**: Optimizes resource deletion for S3 buckets (batch deletion), DynamoDB tables (removes deletion protection), and backup vaults
5. **Main Cleanup**: Executes aws-nuke with comprehensive resource filtering based on configured presets
6. **Error Handling**: Implements intelligent retry logic with resource scaling for recoverable errors (OOM = double CPU/memory)
7. **Monitoring**: Captures detailed logs in CloudWatch for audit trails and troubleshooting

## Safety Guardrails & Best Practices

### Multi-Layer Protection

**1. Protected Accounts List**
- Maintains a comma-separated list of account IDs that should never be cleaned
- Stored in SSM Parameter Store (`/autonuke/blocklist`)
- Checked at the beginning of every execution before any resources are touched
- Execution fails immediately if target account is protected

**2. Resource Filtering with Presets**
- **nuke preset**: Prevents deletion of the autonuke infrastructure itself (CloudFormation stacks, IAM roles containing "nuke")
- **sso preset**: Protects AWS SSO/IAM Identity Center resources (`AWSReservedSSO_*` roles, SAML providers)
- **controltower preset**: Preserves AWS Control Tower infrastructure (stacksets, log groups, SNS topics, etc.)
- **excludebuckets preset**: Skips buckets with specific naming patterns (access logs, CloudTrail, Cloudformation stacks, etc.)
- **excludebackupsnapshots**: Skips deleting snapshots and AMIs that contain a particular tag. This is required if you use AWS Backup and have EBS snapshots or EC2 AMIs. `aws-nuke` tries to delete these resources using EC2 API which fails. The snapshots should be deleted through the backup service instead.

**3. Include-Mode Resource Targeting**
- Uses explicit resource type inclusion rather than exclusion for predictable behavior
- Requires maintenance when new resource types need cleanup, but prevents unexpected deletions
- Resource types must be explicitly listed in the configuration template

**4. Organization Boundary Enforcement**
- Cross-account role assumption is restricted by AWS Organization ID
- Prevents the solution from being used against accounts outside your organization
- Enforced through IAM condition keys in the trust policy

**5. Execution Safeguards**
- Test mode capability for simulating different error scenarios without actual deletion
- Final attempt mode excludes problematic resources (ACM certificates, backup resources) to ensure completion
- Automatic credential refresh for long-running operations (default: 300 seconds remaining threshold)

### Best Practices

**Before Deployment:**
- Test in a dedicated sandbox account first
- Review and customize the resource type inclusion list
- Verify protected accounts list includes all production and critical accounts
- Document the VPC and subnet IDs used for the ECS tasks

**During Operation:**
- Monitor CloudWatch Logs regularly for unexpected errors
- Set up CloudWatch Alarms for failed executions
- Review Step Functions execution history weekly
- Keep the container image updated with the latest aws-nuke version

**For Ongoing Management:**
- Schedule regular reviews of the protected accounts list
- Audit the resource presets as your infrastructure evolves
- Test configuration changes in non-critical accounts first
- Maintain runbooks for common issues and recovery procedures

## Security Considerations

### Cross-Account Role Permissions

The `NukeExecutionRole` deployed in target accounts uses **AdministratorAccess** managed policy. This is a deliberate design choice with important security implications:

**Why Administrator Access?**

aws-nuke needs broad permissions to enumerate and delete resources across all AWS services. The tool discovers resources dynamically and attempts to delete them based on configuration. Specific scenarios requiring elevated permissions include:

- **Service-Specific APIs**: Each AWS service has unique deletion APIs (e.g., `ec2:TerminateInstances`, `s3:DeleteBucket`, `rds:DeleteDBInstance`)
- **Dependency Resolution**: Some resources can't be deleted until dependencies are removed (e.g., VPCs require subnet/route table cleanup first)
- **DynamoDB & RDS Protection**: Disabling deletion protection requires `dynamodb:UpdateTable` and `rds:ModifyDBInstance`
- **Backup Vault Cleanup**: Deleting recovery points requires `backup:DeleteRecoveryPoint` permissions
- **IAM Role Cleanup**: Detaching policies and deleting roles requires multiple IAM permissions

Attempting to craft a minimal permission set would require hundreds of specific actions across 50+ AWS services, and would break whenever:
- You add new resource types to clean up
- AWS introduces new services or changes APIs
- Resources have service-specific protection mechanisms

**Security Mitigations:**

Despite the broad permissions, several controls limit the risk:

1. **Organization Boundary**: The trust policy restricts assumption to principals within your AWS Organization only
   ```yaml
   Condition:
     StringEquals:
       aws:PrincipalOrgID: !Ref OrgId
   ```

2. **Single-Account Scope**: The role can only be assumed from the designated management account (specified by `AutoNukeHostAccount` parameter)

3. **ECS Task Role Limitation**: Only the ECS task role in the management account can assume this role, not individual users

4. **Audit Trail**: All role assumptions and API calls are logged in CloudTrail for security monitoring

5. **Protected Accounts List**: Critical accounts are excluded from cleanup eligibility entirely

6. **No Persistent Credentials**: The role uses temporary STS credentials that expire automatically

**Implementing Restricted Permissions:**

If your use case involves cleaning only specific resource types, you can replace AdministratorAccess with a custom policy:

```yaml
# Example: Restrict to EC2, S3, and Lambda only
Policies:
  - PolicyName: NukeRestrictedPolicy
    PolicyDocument:
      Version: "2012-10-17"
      Statement:
        - Effect: Allow
          Action:
            - ec2:*
            - s3:*
            - lambda:*
            - iam:ListRoles
            - iam:ListPolicies
          Resource: "*"
```

**Important**: Restricted policies require careful testing and maintenance. Missing permissions will cause cleanup failures.

### Additional Security Recommendations

- **Enable CloudTrail**: Ensure all API calls in target accounts are logged for audit purposes
- **MFA for Manual Triggers**: Require MFA for users who can manually trigger the Step Functions state machine
- **Separate Management Account**: Host autonuke infrastructure in a dedicated tools/automation account, not the organization management account
- **Regular Access Reviews**: Audit which accounts have the NukeExecutionRole deployed
- **Alerting**: Set up CloudWatch Alarms for unexpected execution patterns or failures

## Deployment Guide

### 1) Deploy the Infrastructure (CloudFormation)

First, customize the parameters file `cloudformation/parameters/values-autonuke.json`:

```json
[
    {
        "ParameterKey": "ECRRepositoryName",
        "ParameterValue": "aws-nuke"
    },
    {
        "ParameterKey": "VpcId",
        "ParameterValue": "vpc-xxxxxxxxx"
    },
    {
        "ParameterKey": "VpcSubnetId",
        "ParameterValue": "subnet-xxxxxxxxx"
    },
    {
        "ParameterKey": "OrgId",
        "ParameterValue": "o-xxxxxxxxxx"
    },
    {
        "ParameterKey": "AccountBlocklist",
        "ParameterValue": "111111111111,222222222222"
    }
]
```

Deploy the CloudFormation stack (creates ECR, ECS cluster, task definition, IAM roles, Step Functions state machine, and SSM parameter):

```bash
aws cloudformation create-stack \
  --stack-name autonuke-stack \
  --template-body file://cloudformation/auto-nuke.yaml \
  --parameters file://cloudformation/parameters/values-autonuke.json \
  --capabilities CAPABILITY_NAMED_IAM
```

### 2) Build and Push the Container

The Dockerfile installs aws-nuke dynamically from GitHub Releases and adds the runner script:

```Dockerfile
FROM alpine:3.22.1

# Install dependencies
RUN apk add --no-cache bash curl jq unzip aws-cli coreutils

# Fetch the latest version of aws-nuke dynamically and install it
RUN REPO="ekristen/aws-nuke" && \
    ARCH=$(uname -m | sed 's/aarch64/arm64/' | sed 's/x86_64/amd64/') && \
    OS=$(uname -s | tr '[:upper:]' '[:lower:]') && \
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/$REPO/releases/latest) && \
    VERSION=$(echo "$LATEST_RELEASE" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') && \
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/$VERSION/aws-nuke-$VERSION-$OS-$ARCH.tar.gz" && \
    echo "Downloading aws-nuke from $DOWNLOAD_URL" && \
    curl -Lo aws-nuke.tar.gz "$DOWNLOAD_URL" && \
    tar -tzf aws-nuke.tar.gz && \
    tar -xzf aws-nuke.tar.gz -C /usr/local/bin aws-nuke && \
    chmod +x /usr/local/bin/aws-nuke && \
    rm aws-nuke.tar.gz

# Add a shell script to generate the aws-nuke config and run aws-nuke
COPY run-nuke.sh /usr/local/bin/run-nuke.sh
COPY config.yaml.template /root/config.yaml.template
RUN chmod +x /usr/local/bin/run-nuke.sh

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/run-nuke.sh"]
```

Build and push (multi-architecture for both AMD64 and ARM64 Fargate):

```bash
# Authenticate to ECR
aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com

# Build and push multi-arch image
docker buildx build --provenance=false --platform linux/arm64,linux/amd64 \
  -t <account-id>.dkr.ecr.<region>.amazonaws.com/aws-nuke:latest \
  containers/awsnuke --push
```


### 3) Configure Protected Accounts

The CloudFormation stack automatically creates the SSM parameter with the accounts specified in `AccountBlocklist`. You can update it later via AWS CLI:

```bash
aws ssm put-parameter \
  --name "/autonuke/blocklist" \
  --value "111111111111,222222222222,333333333333" \
  --type "String" \
  --overwrite
```

**Best Practice**: Include your organization management account, shared services account, production accounts, and the account hosting autonuke infrastructure.

### 4) Deploy the Execution Role in Target Accounts

The aws-nuke container and runner script both assume the execution role in the target account for cleanup operations. Deploy this stack in **each account you want to clean**:

```bash
aws cloudformation create-stack \
  --stack-name auto-nuke-role \
  --template-body file://cloudformation/nuke-role.yaml \
  --parameters ParameterKey=AutoNukeHostAccount,ParameterValue=<management-account-id> \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile <target-account-profile>
```

For multiple accounts, use StackSets for easier deployment:

```bash
aws cloudformation create-stack-set \
  --stack-set-name autonuke-execution-role \
  --template-body file://cloudformation/nuke-role.yaml \
  --parameters ParameterKey=AutoNukeHostAccount,ParameterValue=<management-account-id> \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation create-stack-instances \
  --stack-set-name autonuke-execution-role \
  --accounts 123456789012 234567890123 345678901234 \
  --regions us-east-1
```

## Configuration

### aws-nuke Config Template

The `containers/awsnuke/config.yaml.template` defines regions, resource types, and safety presets. The runner script injects the protected accounts list and target account ID at runtime.

**Template structure:**

```yaml
blocklist:
  __BLOCKLISTED_ACCOUNTS__

bypass-alias-check-accounts:
  - __ACCOUNT_ID__

regions:
  - eu-west-1
  - eu-north-1
  - us-east-1
  # Update regions according to your needs
```

**Resource Type Strategy:**

aws-nuke can operate in two modes:
- **Exclude-Mode (Not Recommended)**: Attempts to delete *all* resource types except those explicitly excluded. While comprehensive, this approach has significant drawbacks:
  - Scans every AWS API endpoint, including deprecated and legacy services
  - Prone to transient failures from unsupported operations
  - New AWS services are automatically targeted without review
  - Unpredictable behavior as AWS deprecates or changes APIs
- **Include-Mode (Default)**: Only targets explicitly listed resource types, providing:
  - **Predictable behavior**: You control exactly what gets deleted
  - **Stability**: Avoids deprecated API endpoints that cause failures
  - **Safer defaults**: New AWS services require deliberate opt-in
  - **Faster execution**: Reduced API calls mean quicker cleanup cycles
  - **Easier troubleshooting**: Clear scope for debugging issues

**This solution defaults to include-mode** with a curated list of commonly used resource types (EC2, S3, RDS, Lambda, VPC components, etc.). While this requires periodic maintenance to add new resource types, it significantly reduces operational risk and API-related failures. The included configuration template covers 40+ resource types that handle 95% of typical cleanup scenarios.

**Recommendation**: Start with the default include-mode configuration, monitor cleanup results, and incrementally add resource types as needed rather than attempting comprehensive coverage from day one.

Included resource types (excerpt):

```yaml
resource-types:
  includes:
    # Compute
    - EC2Instance
    - EC2Volume
    - EC2Snapshot
    - LambdaFunction
    - ECSCluster
    - EKSCluster

    # Storage
    - S3Bucket  # Handled by pre-cleanup script
    - EFSFileSystem
    - FSxFileSystem

    # Databases
    - RDSDBInstance
    - DynamoDBTable

    # Networking
    - VPC
    - Subnet
    - SecurityGroup
    - ElasticIPAddress

    # Containers
    - ECRRepository

    # IaC
    - CloudFormationStack
```

**Safety Presets:**

Presets filter out resources that should never be deleted:

```yaml
presets:
  nuke:
    filters:
      CloudFormationStack:
        - type: contains
          value: nuke
      IAMRole:
        - type: contains
          value: nuke

  sso:
    filters:
      IAMRole:
        - type: glob
          value: AWSReservedSSO_*
      IAMSAMLProvider:
        - type: regex
          value: "AWSSSO_.*_DO_NOT_DELETE"

  controltower:
    filters:
      CloudFormationStack:
        - type: contains
          value: AWSControlTower
      CloudTrailTrail:
        - type: contains
          value: aws-controltower
      CloudWatchLogsLogGroup:
        - type: contains
          value: aws-controltower
```

### Runner Script Optimizations

Before invoking aws-nuke, the `run-nuke.sh` script performs pre-cleanup optimizations:

**S3 Bucket Deletion (Concurrent & Batched):**

aws-nuke's S3 deletion is slow for buckets with many objects. The runner script uses batch deletion with concurrency:

```bash
# S3 buckets (concurrent deletes, up to 12 parallel jobs)
while read -r bucket; do
  if [[ $bucket =~ -logs- || $bucket =~ accesslogs || $bucket =~ access-logs ]]; then
    echo "Skip bucket: $bucket"
  else
    delete_bucket "$bucket" &
    while [[ $(jobs -r | wc -l) -ge ${MAX_JOBS:-12} ]]; do sleep 1; done
  fi
done < <(aws s3 ls | cut -d" " -f 3)
```

The `delete_bucket` function uses `s3api delete-objects` with batches of 1000 objects, significantly faster than individual deletions.

**DynamoDB Deletion Protection:**

Tables with deletion protection must have it disabled first:

```bash
# Disable DynamoDB deletion protection
for REGION in eu-west-1 eu-central-1; do
  for table in $(aws dynamodb list-tables --region "$REGION" --query 'TableNames[]' --output text || true); do
    aws dynamodb update-table --table-name "$table" --no-deletion-protection-enabled --region "$REGION" || true
  done
done
```

**Backup Vault Cleanup:**

AWS Backup recovery points must be deleted before vaults can be removed:

```bash
for vault in $(aws backup list-backup-vaults --region "$REGION" --query 'BackupVaultList[].BackupVaultName' --output text); do
  for arn in $(aws backup list-recovery-points-by-backup-vault \
      --backup-vault-name "$vault" \
      --region "$REGION" \
      --query 'RecoveryPoints[].RecoveryPointArn' \
      --output text); do

    aws backup delete-recovery-point \
      --backup-vault-name "$vault" \
      --recovery-point-arn "$arn" \
      --region "$REGION" || true
  done
done
```

## Triggering & Scheduling

### Manual Execution

Execute via AWS CLI:

```bash
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:<region>:<account>:stateMachine:AccountCleanupStateMachine \
  --input '{"account_id": "123456789012"}'
```

### EventBridge Scheduled Rule

For weekly cleanup of sandbox accounts:

```json
{
  "Name": "WeeklySandboxCleanup",
  "ScheduleExpression": "cron(0 2 ? * SUN *)",
  "State": "ENABLED",
  "Targets": [
    {
      "Arn": "arn:aws:states:<region>:<account>:stateMachine:AccountCleanupStateMachine",
      "RoleArn": "arn:aws:iam::<account>:role/EventBridgeStepFunctionsRole",
      "Input": "{\"account_id\": \"123456789012\"}"
    }
  ]
}
```

### Lambda Trigger for Multiple Accounts

Create a Lambda function to trigger cleanup for multiple accounts:

```python
import json
import os
import boto3

SFN_ARN = os.environ["STATE_MACHINE_ARN"]
TARGET_ACCOUNTS = os.environ["TARGET_ACCOUNTS"].split(",")

sfn = boto3.client("stepfunctions")

def handler(event, context):
    results = []
    for account_id in TARGET_ACCOUNTS:
        response = sfn.start_execution(
            stateMachineArn=SFN_ARN,
            input=json.dumps({"account_id": account_id.strip()})
        )
        results.append({
            "account_id": account_id.strip(),
            "execution_arn": response["executionArn"]
        })

    return {
        "statusCode": 200,
        "body": json.dumps(results)
    }
```

Environment variables:
- `STATE_MACHINE_ARN`: ARN of the AccountCleanupStateMachine
- `TARGET_ACCOUNTS`: Comma-separated list of account IDs (e.g., "123456789012,234567890123")

### API Gateway Integration

For on-demand triggering via HTTP endpoint:

1. Create an API Gateway REST API
2. Add a POST method that triggers the Lambda function above
3. Enable API key authentication
4. Optionally add request validation to ensure valid account IDs

## Cost Analysis

The autonuke solution is cost-effective, especially compared to the cost of orphaned resources it cleans up.

### Infrastructure Costs (Per Month)

**Fixed Costs:**
- **ECR Repository**: $0.10/GB storage (typically <500MB = $0.05/month)
- **SSM Parameter Store**: Free (standard parameters)
- **Step Functions**: First 4,000 state transitions/month free, then $0.025 per 1,000 transitions
- **CloudWatch Logs**: $0.50/GB ingested, $0.03/GB stored (varies by log volume)

**Variable Costs (Per Execution):**
- **ECS Fargate** (per task):
  - 0.25 vCPU, 512 MB: $0.01221/hour (Linux ARM)
  - 0.5 vCPU, 1 GB: $0.02442/hour (after scaling)
  - Typical execution: 5-30 minutes = $0.001-$0.015 per cleanup
- **Data Transfer**: Negligible (API calls only, no large data transfers)

### Example: Weekly Cleanup of 10 Accounts

**Scenario**: Clean 10 sandbox accounts every Sunday

**Monthly Costs:**
- ECR storage: $0.05
- Step Functions: 40 executions = $0.00 (within free tier)
- ECS Fargate: 40 executions × 15 min avg × $0.01221/hour ≈ $0.12
- CloudWatch Logs: ~100 MB/month ≈ $0.05
- **Total: ~$0.22/month**

**Savings**: If each account has just 1 forgotten t3.medium instance ($30/month), cleaning 10 accounts saves $300/month—a 1,300x ROI.

### Cost Optimization Tips

1. **Use ARM-based Fargate**: ARM tasks cost ~20% less than x86
2. **Adjust log retention**: Set CloudWatch log retention to 7 days for cost savings
3. **Batch executions**: Use Lambda to trigger multiple accounts sequentially rather than parallel executions
4. **Monitor execution time**: Optimize resource type list to skip unused services and reduce runtime

### Cost Comparison: Manual vs. Automated

| Approach | Time Cost | AWS Cost | Risk |
|----------|-----------|----------|------|
| **Manual cleanup** | 2-4 hours engineer time per account | Free | High (human error) |
| **Autonuke (automated)** | 15 min automated per account | $0.005-$0.015 | Low (tested, repeatable) |

**ROI Calculation**: At $100/hour engineer cost, manual cleanup costs $200-$400 per account. Automated cleanup costs <$0.02 per account—a 10,000x improvement.

## Monitoring & Troubleshooting

### CloudWatch Logs

All execution logs are available at:
- **ECS Task Logs**: `/ecs/autonuke` log group
- **Step Functions Logs**: `/aws/vendedlogs/states/AccountCleanupStateMachine/*`

Key log patterns to monitor:
- `"Account .* is protected"` - Protected account check triggered
- `"Failed to assume role"` - IAM permission issues
- `"exit code: 137"` - Out of memory error (triggers automatic scaling)
- `"aws-nuke ran successfully"` - Successful cleanup

### Step Functions Execution History

The Step Functions console provides visual workflow monitoring:
- **Execution status**: Success, failed, running, timed out
- **State transitions**: See which step failed
- **Input/output**: Inspect retry count, CPU/memory scaling
- **Duration**: Track execution time trends

### Common Issues & Solutions

| Issue | Symptom | Solution |
|-------|---------|----------|
| **Protected account rejection** | Execution fails immediately with "protected account" message | Intended behavior—verify target account ID is correct |
| **Role assumption failure** | "Failed to assume role" error | Verify NukeExecutionRole is deployed in target account and trust policy includes management account |
| **Out of memory** | Exit code 137 | State machine automatically doubles CPU/memory and retries |
| **Timeout** | S3 deletion takes too long | Pre-cleanup script handles this; verify MAX_JOBS is set appropriately |
| **Partial cleanup** | Some resources remain | Check aws-nuke config—resource type may not be in includes list |

### Setting Up Alerts

Create CloudWatch Alarms for failed executions:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name AutonukeExecutionFailures \
  --alarm-description "Alert on autonuke Step Functions failures" \
  --metric-name ExecutionsFailed \
  --namespace AWS/States \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions Name=StateMachineArn,Value=arn:aws:states:<region>:<account>:stateMachine:AccountCleanupStateMachine \
  --alarm-actions arn:aws:sns:<region>:<account>:AutonukeAlerts
```

## Conclusion & Next Steps

This solution provides a production-ready approach to automating AWS account cleanups using aws-nuke. By wrapping the powerful aws-nuke tool in a secure, scalable architecture with comprehensive guardrails, you can safely manage account lifecycle operations across your AWS Organization.

### Key Takeaways

- **Safety First**: Multiple layers of protection (protected accounts, resource filters, organization boundaries) prevent accidental damage
- **Scalable**: Handles accounts of any size with automatic resource scaling
- **Cost-Effective**: Pays for itself many times over by eliminating orphaned resources
- **Auditable**: Comprehensive logging and execution history for compliance
- **Extensible**: Easy to customize resource types, regions, and filtering rules

### Recommended Next Steps

**1. Start Small**
- Deploy in a non-critical test account first
- Run with `test_mode` to validate configuration
- Verify logs and monitoring before production use

**2. Establish Cadence**
- **Daily**: Ephemeral CI/CD sandbox accounts
- **Weekly**: Developer sandbox accounts
- **Monthly**: Long-lived test/staging accounts
- **On-demand**: Account offboarding and decommissioning

**3. Integrate with Existing Workflows**
- Connect to AWS Control Tower account factory for new account provisioning
- Trigger cleanup automatically when accounts are tagged for decommissioning
- Include in runbooks for incident response and security remediation

**4. Continuous Improvement**
- Review CloudWatch Logs monthly for patterns and optimization opportunities
- Update resource type lists as new services are adopted
- Test new aws-nuke versions in sandbox before updating production
- Gather feedback from development teams on cleanup effectiveness

**5. Extend Functionality**
- Add Slack/Teams notifications for execution results
- Create a self-service portal for developers to trigger cleanups
- Implement cost tracking to measure savings from cleanup operations
- Build account age policies to automatically clean accounts older than N days

### Scheduling Strategies

**Weekly Sandbox Cleanup:**
```bash
# EventBridge rule: Every Sunday at 2 AM
cron(0 2 ? * SUN *)
```

**Daily CI/CD Environment Cleanup:**
```bash
# EventBridge rule: Every day at 10 PM
cron(0 22 * * ? *)
```

**Quarterly Deep Clean:**
```bash
# EventBridge rule: First Sunday of each quarter
cron(0 2 ? 1,4,7,10 SUN#1 *)
```

**Age-Based Cleanup (Lambda):**
```python
# Cleanup accounts not used in 30+ days
# Query AWS Config or tagging to find inactive accounts
# Trigger Step Functions for each inactive account
```

### Additional Resources

- **aws-nuke documentation**: https://github.com/ekristen/aws-nuke
- **AWS Step Functions best practices**: https://docs.aws.amazon.com/step-functions/latest/dg/best-practices.html
- **ECS Fargate pricing**: https://aws.amazon.com/fargate/pricing/
- **IAM cross-account access**: https://docs.aws.amazon.com/IAM/latest/UserGuide/tutorial_cross-account-with-roles.html

### Contributing

If you implement improvements or additional safety features, consider contributing back:
- Enhanced resource type coverage
- Additional safety presets for other AWS services (e.g., AWS Config, GuardDuty)
- Cost optimization techniques
- Integration examples with other AWS services

### Final Thoughts

Account cleanup is a crucial but often overlooked aspect of AWS management. Automating this process not only saves time and money but also improves security posture and compliance. With proper guardrails and monitoring, autonuke can become a trusted part of your AWS operations toolkit.

Remember: **Test thoroughly, start small, and always verify your protected accounts list before deploying to production.**
