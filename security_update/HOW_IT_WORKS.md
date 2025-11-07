# How the Security Update Scripts Work

## Purpose

**These scripts are designed to update EXISTING LCA deployments that are already running in AWS.** They apply security patches to live ECS containers and EC2 instances without requiring a complete redeployment.

> ⚠️ **Important**: These scripts are for updating existing deployments only. Fresh deployments automatically include all security fixes and don't need these scripts.

## What Gets Updated

### ECS Container Images
- **Target**: WebSocket Transcriber containers running in ECS Fargate
- **Updates**: Base OS packages (ncurses, gnutls, glibc, util-linux, tar)
- **Method**: Rebuild Docker images with security patches, push to ECR, update ECS service

### EC2 Instances  
- **Target**: Asterisk server instances (if Demo PBX is enabled)
- **Updates**: Ubuntu packages (liburiparser1, libopusfile0)
- **Method**: Apply patches via SSM or replace instance via CloudFormation

## How Each Script Works

### 1. Main Deployment Scripts

#### `security-update-deployment.sh`
```bash
./security-update-deployment.sh LCA-YOUR-STACK-NAME
```

**What it does:**
1. **Container Update Process:**
   - Navigates to `lca-websocket-transcriber-stack`
   - Runs the build script to create new Docker images
   - Pushes updated images to ECR
   - Updates ECS service to use new images
   - Waits for rolling deployment to complete

2. **EC2 Update Process:**
   - Finds EC2 instances in the CloudFormation stack
   - Attempts in-place updates via SSM commands
   - Triggers CloudFormation stack update to replace instances
   - Monitors update progress

**Behind the scenes:**
- Uses AWS CLI to interact with ECS, ECR, EC2, and CloudFormation
- Maintains zero-downtime by using rolling updates
- Preserves all existing configuration and data

#### `minimal-security-update.sh`
```bash
./minimal-security-update.sh LCA-YOUR-STACK-NAME
```

**What it does:**
- Creates a temporary Dockerfile with only security patches
- Uses Node.js 18 instead of 20 for maximum compatibility
- Applies OS-level security updates without changing application dependencies
- Restores original Dockerfile if deployment fails

**When to use:**
- Production environments where stability is critical
- When you want security fixes without any application changes
- If the main deployment script encounters compatibility issues

### 2. Troubleshooting Scripts

#### `fix-dependencies.sh`
```bash
./fix-dependencies.sh
```

**What it does:**
1. Deletes `package-lock.json` file
2. Clears npm cache completely
3. Runs `npm install` to regenerate lock file
4. Tests the build to ensure compatibility

**Why it's needed:**
- When package.json is updated but package-lock.json is out of sync
- Resolves version conflicts between dependencies
- Fixes npm build errors during container updates

#### `fix-platform-architecture.sh`
```bash
./fix-platform-architecture.sh LCA-YOUR-STACK-NAME
```

**What it does:**
1. Rebuilds Docker images with explicit `--platform linux/amd64` flag
2. Pushes corrected images to ECR
3. Updates ECS service to use new images
4. Monitors deployment until tasks are running

**Why it's needed:**
- ECS Fargate requires linux/amd64 platform
- Fixes "manifest descriptor" errors
- Ensures containers can start properly on AWS infrastructure

#### `fix-patch-manager.sh`
```bash
./fix-patch-manager.sh i-1234567890abcdef0
# or
./fix-patch-manager.sh LCA-YOUR-STACK-NAME
```

**What it does:**
1. **Detects input type**: Automatically determines if you provided an instance ID or CloudFormation stack name
2. **Checks patch state**: Verifies if instance has patch management data or shows "RESOURCE_NOT_REPORTING"
3. **Validates SSM agent**: Confirms agent is online, checks version, updates if needed
4. **Configures patch groups**: Adds "Patch Group" tag if missing for proper patch targeting
5. **Runs patch scan**: Executes initial or refresh patch baseline scan to populate patch state
6. **Monitors completion**: Waits for scan to finish and shows results
7. **Verifies fix**: Confirms patch state is now available and reports patch counts

**Why it's needed:**
- Resolves "RESOURCE_NOT_REPORTING" errors in AWS Patch Manager
- Fixes instances that were deployed before patch management was configured
- Updates outdated SSM agents that can't communicate properly with patch services
- Ensures instances are properly tagged and configured for automated patch management

**Technical details:**
- Uses `aws ssm describe-instance-patch-states` to check current patch status
- Sends `AWS-RunPatchBaseline` commands with "Scan" operation to populate patch data
- Updates SSM agent via `snap refresh amazon-ssm-agent` for Ubuntu instances
- Adds EC2 tags for patch group association
- Provides real-time feedback on command execution status

### 3. Discovery Scripts

#### `find-asterisk-instance.sh`
```bash
./find-asterisk-instance.sh LCA-YOUR-MAIN-STACK-NAME
```

**What it does:**
1. **Searches main CloudFormation stack** for EC2 instances
2. **Searches nested stacks** (where Asterisk is usually deployed)
3. **Searches all EC2 instances** with "Asterisk" in the name
4. **Displays detailed information** about found instances
5. **Provides specific commands** for updating each instance

**Why it's needed:**
- LCA architecture uses nested CloudFormation stacks
- Asterisk instances are often in different stacks than expected
- Helps locate the correct stack name for other scripts

#### `update-ec2-security.sh`
```bash
./update-ec2-security.sh LCA-YOUR-NESTED-STACK-NAME
```

**What it does:**
1. **Finds EC2 instance** in the specified CloudFormation stack
2. **Attempts SSM update:**
   - Sends commands via AWS Systems Manager
   - Runs `apt-get update && apt-get upgrade`
   - Installs specific security patches
   - Monitors command execution
3. **Triggers CloudFormation update:**
   - Updates stack with new version parameter
   - Forces instance replacement with security patches
   - Optionally waits for completion

**How SSM works:**
- Requires SSM agent running on the instance
- Executes commands remotely without SSH
- Provides real-time feedback on command status

### 4. Verification Scripts

#### `verify-security-updates.sh`
```bash
./verify-security-updates.sh LCA-YOUR-STACK-NAME
```

**What it does:**
1. **Checks ECS Service:**
   - Verifies running task count matches desired count
   - Shows current task definition version
   - Indicates if deployment is in progress

2. **Checks EC2 Instance:**
   - Verifies instance is running
   - Sends SSM command to check package versions
   - Provides command ID for monitoring

**Output interpretation:**
- ✅ Green checkmarks = Everything working correctly
- ⚠️ Yellow warnings = May need attention but not critical
- ❌ Red errors = Issues that need immediate attention

#### `verify-patch-management.sh`
```bash
./verify-patch-management.sh LCA-YOUR-STACK-NAME
```

**What it does:**
1. **SSM Agent Check:**
   - Verifies agent is online and registered
   - Checks agent version and update status
   - Confirms communication with AWS

2. **Patch Baseline Check:**
   - Looks for custom patch baselines
   - Verifies patch group associations
   - Shows maintenance window schedules

3. **Patch State Check:**
   - Shows last patch scan results
   - Displays installed/missing/failed patch counts
   - Initiates scan if no state exists

## Technical Implementation Details

### Container Update Process

1. **Docker Build Process:**
   ```bash
   # The scripts run commands like this:
   docker build --platform linux/amd64 -t $ECR_URI source/app/
   docker push $ECR_URI
   ```

2. **ECS Service Update:**
   ```bash
   # Creates new task definition with updated image
   aws ecs register-task-definition --family MyFamily --container-definitions [...]
   aws ecs update-service --cluster MyCluster --service MyService --task-definition NewTaskDef
   ```

3. **Rolling Deployment:**
   - ECS starts new tasks with updated images
   - Waits for health checks to pass
   - Stops old tasks gradually
   - Maintains service availability throughout

### EC2 Update Process

1. **SSM Command Execution:**
   ```bash
   # Scripts send commands like this:
   aws ssm send-command \
     --instance-ids i-1234567890abcdef0 \
     --document-name "AWS-RunShellScript" \
     --parameters 'commands=["sudo apt-get update", "sudo apt-get upgrade -y"]'
   ```

2. **CloudFormation Stack Update:**
   ```bash
   # Forces instance replacement by changing parameters:
   aws cloudformation update-stack \
     --stack-name MyStack \
     --parameters ParameterKey=Version,ParameterValue=20231105120000
   ```

3. **Instance Replacement:**
   - CloudFormation creates new instance with updated UserData
   - New instance automatically gets security patches during boot
   - Old instance is terminated after new one is healthy
   - Elastic IP and other resources are transferred

### Error Handling

The scripts include comprehensive error handling:

- **Rollback mechanisms** if deployments fail
- **Timeout handling** for long-running operations
- **Validation checks** before making changes
- **Detailed logging** for troubleshooting
- **Graceful degradation** when optional features aren't available

### Safety Features

- **Backup creation** before making changes
- **Confirmation prompts** for destructive operations
- **Status monitoring** throughout the process
- **Detailed output** showing what's happening
- **Exit codes** for automation and scripting

## When NOT to Use These Scripts

❌ **Don't use these scripts if:**
- You're deploying LCA for the first time (fresh deployments include all fixes)
- Your deployment is in a critical production window
- You haven't tested the scripts in a development environment first
- You don't have proper AWS permissions
- You're not familiar with the LCA architecture

✅ **Use these scripts when:**
- You have an existing LCA deployment with security vulnerabilities
- You need to apply security patches to running systems
- You want to update without full redeployment
- You've tested the process in a non-production environment

## Monitoring and Validation

After running the scripts:

1. **Check AWS Console:**
   - CloudFormation: Verify stack updates completed successfully
   - ECS: Confirm services are running with desired task count
   - EC2: Verify instances are running and healthy

2. **Run Verification Scripts:**
   - Use `verify-security-updates.sh` to confirm patches applied
   - Use `verify-patch-management.sh` to check ongoing patch management

3. **Test Application Functionality:**
   - Verify LCA web interface is accessible
   - Test call transcription functionality
   - Check CloudWatch logs for any errors

4. **Security Validation:**
   - Re-run security scans to confirm vulnerabilities resolved
   - Check AWS Security Hub for updated findings
   - Verify compliance requirements are met

This approach ensures your existing LCA deployment gets security updates while maintaining operational stability and service availability.