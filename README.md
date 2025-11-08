# AutoNuke: Automated AWS Account Cleanup

This repository contains infrastructure and automation for safely cleaning up AWS accounts using aws-nuke. The solution uses AWS Step Functions, ECS Fargate, and a containerized aws-nuke tool to systematically remove resources from target accounts while protecting critical infrastructure.

## Overview

AutoNuke provides a production-ready solution for automating AWS account cleanups with:
- **Multi-layer protection**: Protected accounts list, organization boundaries, and resource filtering
- **Intelligent retry logic**: Automatic resource scaling on out-of-memory errors
- **Comprehensive resource coverage**: 30+ AWS resource types including EC2, S3, RDS, Lambda, VPCs, and more
- **Pre-cleanup optimizations**: Efficient S3 bucket deletion, DynamoDB protection removal, and backup vault cleanup

## Prerequisites

- AWS Organization with multiple accounts
- Organization ID for restricting cross-account access
- Designated "management" or "tools" account to host the autonuke infrastructure
- Administrator-level permissions in the management account
- Existing VPC with at least one subnet that has internet access
- AWS CLI configured with appropriate credentials
- Docker with buildx support for multi-architecture builds

## Configuration

### CloudFormation Parameters

- `AwsNukeClusterName`: Name of the ECS cluster (default: aws-nuke-cluster)
- `ECRRepositoryName`: Name of the ECR repository (required)
- `VpcId`: VPC ID for the ECS cluster (required)
- `VpcSubnetId`: Subnet ID for ECS tasks (required)
- `OrgId`: AWS Organization ID for cross-account access (required)
- `AccountBlocklist`: Comma-delimited list of protected account IDs that cannot be nuked (required)
- `MaxRetries`: Maximum retry attempts (default: 3)
- `NukeExecutionRoleName`: Role name for aws-nuke execution (default: NukeExecutionRole)
- `AwsRegions`: Comma-delimited list of AWS regions to process (default: eu-north-1,eu-west-1)
- `NukeMaxJobs`: Maximum number of concurrent S3 deletion jobs (default: 12)
- `NukeRefreshThreshold`: Refresh credentials when less than this many seconds remaining (default: 300)
- `ExcludeBucketPrefixes`: Optional - Comma-delimited list of S3 bucket name prefixes to exclude from deletion. If not provided or empty, all buckets will be deleted.

## Deployment Instructions

### Step 1: Deploy Infrastructure

Deploy the CloudFormation stack (this creates the ECR repository, ECS cluster, task definition, IAM roles, Step Functions state machine, and SSM parameter):

```bash
aws cloudformation create-stack \
  --stack-name autonuke-stack \
  --template-body file://cloudformation/auto-nuke.yaml \
  --parameters file://cloudformation/parameters/values-autonuke.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile <target-aws-account-profile>
```

Wait for the stack to complete. You can check the status with:
```bash
aws cloudformation describe-stacks --stack-name autonuke-stack --query 'Stacks[0].StackStatus'
```

Once the stack is created, get the ECR repository URI from the stack outputs:
```bash
aws cloudformation describe-stacks \
  --stack-name autonuke-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`ECRRepository`].OutputValue' \
  --output text
```

### Step 2: Build and Push Container

```bash
cd containers/awsnuke
```

Log in to the ECR registry (replace `<account-id>` and `<region>` with your values):
```bash
aws ecr get-login-password --region <region> --profile <ECR-account> | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com
```

Build and push the container for production (replace `<account-id>`, `<region>`, and `<repository-name>` with your values):
```bash
docker buildx build --provenance=false --platform linux/arm64,linux/amd64 \
  -t <account-id>.dkr.ecr.<region>.amazonaws.com/<repository-name>:latest \
  . --push
```

### Step 3: Configure Protected Accounts

The CloudFormation stack automatically creates the SSM parameter with the accounts specified in `AccountBlocklist`. You can update it later via AWS CLI:

```bash
aws ssm put-parameter \
  --name "/autonuke/blocklist" \
  --value "123456789012,234567890123,345678901234" \
  --type "String" \
  --overwrite
```

**Best Practice**: Include your organization management account, shared services account, production accounts, and the account hosting autonuke infrastructure.

### Step 4: Deploy the Execution Role in Target Accounts

The aws-nuke container assumes the execution role in the target account for cleanup operations. Deploy this stack in **each account you want to clean**:

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

## Usage

### Manual Execution

Execute via AWS CLI:
```bash
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:<region>:<account>:stateMachine:AccountCleanupStateMachine \
  --input '{"account_id": "123456789012"}'
```

Or via AWS Console: Navigate to Step Functions and execute the `AccountCleanupStateMachine`

### Scheduled Execution

For weekly cleanup of sandbox accounts, create an EventBridge scheduled rule:

```bash
aws events put-rule \
  --name WeeklySandboxCleanup \
  --schedule-expression "cron(0 2 ? * SUN *)" \
  --state ENABLED

aws events put-targets \
  --rule WeeklySandboxCleanup \
  --targets "Id"="1","Arn"="arn:aws:states:<region>:<account>:stateMachine:AccountCleanupStateMachine","RoleArn"="arn:aws:iam::<account>:role/EventBridgeStepFunctionsRole","Input"="{\"account_id\": \"123456789012\"}"
```

### Input Format

The state machine expects the following input:
```json
{
  "account_id": "123456789012"
}
```

## Monitoring

**CloudWatch Logs:**
- **ECS Task Logs**: `/ecs/autonuke` log group
- **Step Functions Logs**: `/aws/vendedlogs/states/AccountCleanupStateMachine/*`

**Key log patterns to monitor:**
- `"Account .* is protected"` - Protected account check triggered
- `"Failed to assume role"` - IAM permission issues
- `"exit code: 137"` - Out of memory error (triggers automatic scaling)
- `"aws-nuke ran successfully"` - Successful cleanup

## Troubleshooting

| Issue | Symptom | Solution |
|-------|---------|----------|
| **Protected account rejection** | Execution fails immediately with "protected account" message | Intended behavior. Reconfigure /autonuke/blocklist parameter as needed |
| **Role assumption failure** | "Failed to assume role" error | Verify NukeExecutionRole is deployed in target account and trust policy includes management account |
| **Container out of memory** | Exit code 137 | State machine automatically doubles CPU/memory and retries |
| **Partial cleanup** | Some resources remain | Check aws-nuke config—resource type may not be in includes list |

## Security

The `NukeExecutionRole` deployed in target accounts uses **AdministratorAccess** managed policy. This is a deliberate design choice because aws-nuke needs broad permissions to enumerate and delete resources across all AWS services.

**Security mitigations:**
- **Organization boundary enforcement**: The trust policy restricts role assumption to principals within your AWS Organization only
- **Deployment scope**: The role is only deployed in accounts that should be targeted by autonuke (not in production or protected accounts)
- **Single-account scope**: The role can only be assumed from the designated management account
- **ECS task role limitation**: Only the ECS task role in the management account can assume this role, not individual users
- **Protected accounts list**: Critical accounts are excluded from cleanup eligibility entirely
- **Audit trail**: All role assumptions and API calls are logged in CloudTrail for security monitoring

## Architecture & Design

For detailed architecture information, design considerations, security best practices, cost analysis, and advanced configuration options, see the blog post:

**https://floccus.se/blog/autonuke**
