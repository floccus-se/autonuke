# AutoNuke: Automated AWS Account Cleanup

This repository contains infrastructure and automation for safely cleaning up AWS accounts using aws-nuke. The solution uses AWS Step Functions, ECS Fargate, and a containerized aws-nuke tool to systematically remove resources from target accounts while protecting critical infrastructure.

## Architecture Overview

The solution consists of several key components working together:

### Core Components

1. **AWS Step Functions State Machine** (`AccountCleanupStateMachine`)
   - Orchestrates the entire cleanup process
   - Handles retry logic with configurable maximum attempts
   - Manages error handling and failure scenarios
   - Provides centralized logging and monitoring

2. **ECS Fargate Task**
   - Runs the containerized aws-nuke tool
   - Executes in a secure, isolated environment
   - Supports both ARM64 and AMD64 architectures
   - Configured with appropriate CPU (256) and memory (512 MB)

3. **Containerized aws-nuke**
   - Alpine Linux-based container with aws-nuke tool
   - Dynamically fetches the latest aws-nuke version during build
   - Includes custom cleanup scripts for S3 buckets and other resources
   - Pre-configured with comprehensive resource filters

4. **IAM Roles and Policies**
   - `AccountCleanupExecutionRole`: Step Functions execution role
   - `NukeEcsTaskRole`: ECS task execution role with cross-account permissions
   - Cross-account role assumption for target account access

### Security Features

- **Protected Accounts**: A list of accounts that should never be nuked. This feature can be configured using the SSM parameter (`/autonuke/blocklist`).
- **Cross-Account Role Assumption**: Uses organization-based trust policies
- **Resource Filtering**: Comprehensive filters to protect critical AWS services
- **Network Isolation**: ECS tasks run in private subnets with restricted security groups

## Resource Cleanup Strategy

The solution handles different resource types with specialized approaches:

### S3 Buckets
- Custom script handles S3 bucket deletion efficiently
- Batch operations for object version deletion
- Concurrent processing with configurable job limits
- Automatic exclusion of log buckets (`*-logs-*`, `accesslogs`, `elasticbeanstalk-*`)

### DynamoDB Tables
- Automatically disables deletion protection before cleanup
- Processes multiple regions concurrently

### AWS Backup Resources
- Pre-cleans backup vaults and recovery points
- Excludes backup resources in final retry attempts

### Comprehensive Resource Coverage
The solution targets 30+ AWS resource types including:
- Compute: EC2 instances, volumes, snapshots, AMIs, Lambda functions
- Storage: EFS, FSx, S3 buckets, EBS volumes
- Databases: RDS instances/clusters, DynamoDB tables, Redshift clusters
- Networking: VPCs, subnets, security groups, Elastic IPs
- Monitoring: CloudWatch logs, metrics, Config rules
- Containers: ECR repositories, ECS clusters, EKS clusters
- And many more...

## Configuration

### CloudFormation Parameters

The infrastructure is deployed using CloudFormation with the following parameters:

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

### aws-nuke Configuration

The container includes a comprehensive configuration template (`config.yaml.template`) with:

- **Presets**: Common, SSO, Control Tower, and custom filters
- **Resource Types**: 30+ AWS resource types for cleanup
- **Regions**: Dynamically configured via the `AwsRegions` CloudFormation parameter and passed as an environment variable to the container
- **Protection Rules**: Excludes critical AWS services and infrastructure

The regions are automatically populated in the aws-nuke configuration at runtime based on the `REGIONS` environment variable, which is set from the CloudFormation parameter.

## Deployment Instructions

### Prerequisites

1. AWS CLI configured with appropriate permissions
2. Docker installed for container building
3. Access to the target AWS account and ECR registry

### Step 1: Build and Push Container

```bash
cd containers/awsnuke
```

Log in to the ECR registry:
```bash
aws ecr get-login-password --region eu-west-1 --profile <ECR-account> | docker login --username AWS --password-stdin <registry-url>
```

Build and push the container for production:
```bash
docker buildx build --provenance=false --platform linux/arm64,linux/amd64 -t <registry-url>/aws-nuke:latest . --push
```

### Step 2: Deploy Infrastructure

Deploy the CloudFormation stack:
```bash
aws cloudformation create-stack \
  --stack-name autonuke-stack \
  --template-body file://cloudformation/auto-nuke.yaml \
  --parameters file://cloudformation/parameters/values-autonuke.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile <target-aws-account-profile>
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

## Usage

### Triggering the State Machine

The state machine can be triggered in several ways:

1. **AWS Console**: Navigate to Step Functions and execute the `AccountCleanupStateMachine`
2. **AWS CLI**: Use the `start-execution` command
3. **AWS Service Catalog**: Create a product that triggers the state machine
4. **API Gateway**: Create an API endpoint that triggers the state machine

### Input Format

The state machine expects the following input:
```json
{
  "account_id": "123456789012"
}
```

### Monitoring and Logging

- **Step Functions**: Monitor execution status in the AWS Console
- **CloudWatch Logs**: Container logs are available in `/ecs/autonuke` log group
- **ECS Console**: Monitor task execution and resource usage

### Retry Logic

The state machine includes intelligent retry logic:
- Configurable maximum retry attempts (default: 3)
- Exponential backoff between retries
- Final attempt excludes problematic resources (Backup services)
- Comprehensive error handling and reporting

## Safety Features

### Account Protection
- Protected accounts list prevents accidental cleanup of critical accounts
- Organization-based role assumption ensures proper access control
- Comprehensive resource filters protect AWS-managed services

### Resource Filtering
- **Control Tower**: Excludes all Control Tower managed resources
- **SSO**: Protects AWS SSO related resources
- **Common**: Excludes standard AWS service roles and resources
- **Custom**: Additional filters for specific organizational needs

### Error Handling
- Graceful handling of resource deletion failures
- Detailed logging for troubleshooting
- Automatic credential refresh during long-running operations
- Timeout protection (10-hour maximum execution time)

## Troubleshooting

### Common Issues

1. **Permission Errors**: Ensure the execution role has proper cross-account permissions
2. **S3 Bucket Deletion**: Check for bucket policies or MFA requirements
3. **DynamoDB Protection**: Verify deletion protection is properly disabled
4. **Backup Resources**: Check if backup vaults have recovery points

### Log Analysis

Check CloudWatch logs at `/ecs/autonuke` for detailed execution information:
- Role assumption status
- Resource discovery and deletion progress
- Error messages and stack traces
- Performance metrics

## Security Considerations

- All operations are logged and auditable
- Cross-account access is limited to organization members
- Sensitive resources are protected by comprehensive filters
- Container runs in isolated network environment
- Credentials are automatically refreshed to prevent expiration

## Architecture

A blog post about architecture and design considerations:
https://floccus.se/blog/autonuke