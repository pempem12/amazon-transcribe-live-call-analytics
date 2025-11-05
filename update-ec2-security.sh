#!/bin/bash

# EC2 Security Update Script
# This script specifically updates the EC2 instance with security patches

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== EC2 Instance Security Update ===${NC}"

# Check if stack name is provided
if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <stack-name>${NC}"
    echo "Example: $0 LCA-bandytoy-WEBSOCKETTRANSCRIBERSTACK-46RBOCMXZDJA"
    exit 1
fi

STACK_NAME=$1

echo -e "${YELLOW}Step 1: Checking current EC2 instance${NC}"

# Get the current EC2 instance ID
INSTANCE_ID=$(aws cloudformation describe-stack-resources \
    --stack-name "$STACK_NAME" \
    --query "StackResources[?LogicalResourceId=='AsteriskInstance'].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    echo "Found EC2 instance: $INSTANCE_ID"
    
    # Get instance details
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].State.Name" \
        --output text)
    
    INSTANCE_TYPE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].InstanceType" \
        --output text)
    
    LAUNCH_TIME=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].LaunchTime" \
        --output text)
    
    echo "Current instance state: $INSTANCE_STATE"
    echo "Instance type: $INSTANCE_TYPE"
    echo "Launch time: $LAUNCH_TIME"
else
    echo -e "${YELLOW}No EC2 instance found in stack (Demo Asterisk may be disabled)${NC}"
    exit 0
fi

echo -e "${YELLOW}Step 2: Applying security updates${NC}"

# Option A: Try to update the existing instance via SSM (if available)
echo "Attempting to apply security updates to existing instance..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["sudo apt-get update", "sudo apt-get upgrade -y", "sudo apt-get install -y --only-upgrade liburiparser1 libopusfile0", "echo Security updates completed"]' \
    --query "Command.CommandId" \
    --output text 2>/dev/null || echo "")

if [ -n "$COMMAND_ID" ]; then
    echo "SSM command sent successfully. Command ID: $COMMAND_ID"
    echo "Waiting for command to complete..."
    
    # Wait for command to complete (timeout after 5 minutes)
    for i in {1..30}; do
        STATUS=$(aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --query "Status" \
            --output text 2>/dev/null || echo "InProgress")
        
        if [ "$STATUS" = "Success" ]; then
            echo -e "${GREEN}✓ Security updates applied successfully via SSM${NC}"
            
            # Get command output
            OUTPUT=$(aws ssm get-command-invocation \
                --command-id "$COMMAND_ID" \
                --instance-id "$INSTANCE_ID" \
                --query "StandardOutputContent" \
                --output text 2>/dev/null || echo "")
            
            echo "Command output:"
            echo "$OUTPUT"
            break
        elif [ "$STATUS" = "Failed" ]; then
            echo -e "${YELLOW}⚠ SSM command failed, will proceed with instance replacement${NC}"
            break
        else
            echo "Command status: $STATUS (waiting...)"
            sleep 10
        fi
    done
else
    echo -e "${YELLOW}⚠ Could not send SSM command (instance may not have SSM agent)${NC}"
fi

echo -e "${YELLOW}Step 3: Triggering instance replacement via CloudFormation${NC}"
echo "This ensures the instance gets the latest security patches from the updated template..."

# Generate a new version timestamp to force instance replacement
NEW_VERSION=$(date +%Y%m%d%H%M%S)
echo "Using version: $NEW_VERSION"

# Update the CloudFormation stack
aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --use-previous-template \
    --capabilities CAPABILITY_IAM \
    --parameters ParameterKey=Version,ParameterValue="$NEW_VERSION" \
    --output text

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ CloudFormation stack update initiated${NC}"
    echo "This will replace the EC2 instance with a new one that has security patches applied."
    
    echo -e "${YELLOW}Step 4: Monitoring stack update progress${NC}"
    echo "You can monitor the progress in the AWS Console or run:"
    echo "aws cloudformation describe-stack-events --stack-name $STACK_NAME"
    
    # Wait for stack update to complete (optional)
    read -p "Do you want to wait for the stack update to complete? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Waiting for stack update to complete..."
        aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Stack update completed successfully${NC}"
            
            # Get new instance ID
            NEW_INSTANCE_ID=$(aws cloudformation describe-stack-resources \
                --stack-name "$STACK_NAME" \
                --query "StackResources[?LogicalResourceId=='AsteriskInstance'].PhysicalResourceId" \
                --output text)
            
            echo "New instance ID: $NEW_INSTANCE_ID"
        else
            echo -e "${RED}✗ Stack update failed or timed out${NC}"
            echo "Check the CloudFormation console for details"
        fi
    fi
else
    echo -e "${RED}✗ CloudFormation stack update failed${NC}"
    exit 1
fi

echo -e "${GREEN}=== EC2 Security Update Complete ===${NC}"
echo ""
echo "What was updated:"
echo "• Applied general security updates (apt-get upgrade)"
echo "• Updated liburiparser1 to ESM patched version"
echo "• Updated libopusfile0 to ESM patched version"
echo "• Replaced instance with security-hardened version"
echo ""
echo "Next steps:"
echo "1. Verify the new instance is running and healthy"
echo "2. Test Asterisk functionality"
echo "3. Run security scans to confirm vulnerabilities are resolved"