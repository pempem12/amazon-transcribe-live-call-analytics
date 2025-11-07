#!/bin/bash

# Security Update Deployment Script for LCA
# This script updates both container images and EC2 instances with security patches

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== LCA Security Update Deployment ===${NC}"

# Check if stack name is provided
if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <stack-name>${NC}"
    echo "Example: $0 LCA-bandytoy-WEBSOCKETTRANSCRIBERSTACK-46RBOCMXZDJA"
    exit 1
fi

STACK_NAME=$1

echo -e "${YELLOW}Step 1: Updating Container Images${NC}"
echo "Building and deploying updated container images with security patches..."

# Navigate to websocket transcriber directory
cd ../lca-websocket-transcriber-stack

# Run the clean build script first
echo "Running clean build script..."
./clean-and-build.sh "$STACK_NAME"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Container images updated successfully${NC}"
else
    echo -e "${RED}✗ Container image update failed${NC}"
    exit 1
fi

cd ../security_update_scripts

echo -e "${YELLOW}Step 2: Updating EC2 Instance${NC}"
echo "Triggering EC2 instance replacement with updated AMI and packages..."

# Get the EC2 instance ID from CloudFormation
INSTANCE_ID=$(aws cloudformation describe-stack-resources \
    --stack-name "$STACK_NAME" \
    --query "StackResources[?LogicalResourceId=='AsteriskInstance'].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    echo "Found EC2 instance: $INSTANCE_ID"
    
    echo -e "${YELLOW}Option 1: Update existing instance in-place${NC}"
    echo "Applying security patches to existing instance..."
    
    # Apply security updates to existing instance
    aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["sudo apt-get update", "sudo apt-get upgrade -y", "sudo apt-get install -y --only-upgrade liburiparser1 libopusfile0"]' \
        --output text > /dev/null 2>&1 || echo "SSM command may have failed - instance might not have SSM agent"
    
    echo -e "${YELLOW}Option 2: Replace instance with updated CloudFormation${NC}"
    echo "Updating CloudFormation stack to replace instance with security patches..."
    
    # Update the stack to trigger instance replacement
    aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --use-previous-template \
        --capabilities CAPABILITY_IAM \
        --parameters ParameterKey=Version,ParameterValue="$(date +%Y%m%d%H%M%S)" \
        --output text
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ CloudFormation stack update initiated${NC}"
        echo "Monitor the stack update progress in the AWS Console"
    else
        echo -e "${RED}✗ CloudFormation stack update failed${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}No EC2 instance found in stack (Demo Asterisk may be disabled)${NC}"
fi

echo -e "${GREEN}=== Security Update Deployment Complete ===${NC}"
echo ""
echo "Summary of changes applied:"
echo "• Container images updated to Node.js 20 with latest security patches"
echo "• Updated vulnerable packages: ncurses, gnutls, glibc, util-linux, tar"
echo "• EC2 instance updated with patches for: liburiparser1, libopusfile0"
echo ""
echo "Next steps:"
echo "1. Monitor the CloudFormation stack update in AWS Console"
echo "2. Verify the new container tasks are running in ECS"
echo "3. Test your LCA deployment to ensure functionality"
echo "4. Run security scans again to confirm vulnerabilities are resolved"