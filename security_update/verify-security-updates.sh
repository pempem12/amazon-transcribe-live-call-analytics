#!/bin/bash

# Security Update Verification Script for LCA
# This script verifies that security patches have been applied

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== LCA Security Update Verification ===${NC}"

# Check if stack name is provided
if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <stack-name>${NC}"
    echo "Example: $0 LCA-bandytoy-WEBSOCKETTRANSCRIBERSTACK-46RBOCMXZDJA"
    exit 1
fi

STACK_NAME=$1

echo -e "${YELLOW}Step 1: Checking Container Image Updates${NC}"

# Get ECS cluster and service information
CLUSTER_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name "$STACK_NAME" \
    --logical-resource-id TranscribingCluster \
    --query "StackResources[0].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")

SERVICE_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name "$STACK_NAME" \
    --logical-resource-id TranscriberWebsocketFargateService \
    --query "StackResources[0].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")

if [ -n "$CLUSTER_NAME" ] && [ -n "$SERVICE_NAME" ]; then
    echo "Checking ECS service status..."
    RUNNING_COUNT=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --query "services[0].runningCount" \
        --output text)
    
    DESIRED_COUNT=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --query "services[0].desiredCount" \
        --output text)
    
    if [ "$RUNNING_COUNT" = "$DESIRED_COUNT" ]; then
        echo -e "${GREEN}✓ ECS service is running with $RUNNING_COUNT/$DESIRED_COUNT tasks${NC}"
    else
        echo -e "${YELLOW}⚠ ECS service is updating: $RUNNING_COUNT/$DESIRED_COUNT tasks running${NC}"
    fi
    
    # Get the current task definition
    TASK_DEFINITION=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --query "services[0].taskDefinition" \
        --output text)
    
    echo "Current task definition: $TASK_DEFINITION"
else
    echo -e "${YELLOW}No ECS cluster/service found in stack${NC}"
fi

echo -e "${YELLOW}Step 2: Checking EC2 Instance Updates${NC}"

# Get the EC2 instance ID from CloudFormation
INSTANCE_ID=$(aws cloudformation describe-stack-resources \
    --stack-name "$STACK_NAME" \
    --query "StackResources[?LogicalResourceId=='AsteriskInstance'].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    echo "Found EC2 instance: $INSTANCE_ID"
    
    # Check instance state
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].State.Name" \
        --output text)
    
    echo "Instance state: $INSTANCE_STATE"
    
    if [ "$INSTANCE_STATE" = "running" ]; then
        echo -e "${GREEN}✓ EC2 instance is running${NC}"
        
        # Try to check package versions via SSM
        echo "Attempting to verify package versions..."
        COMMAND_ID=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["dpkg -l | grep -E \"liburiparser1|libopusfile0|ncurses|gnutls|libc6|util-linux|tar\" | awk \"{print \\$2, \\$3}\""]' \
            --query "Command.CommandId" \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$COMMAND_ID" ]; then
            echo "SSM command sent. Command ID: $COMMAND_ID"
            echo "Check SSM Run Command console for package version details"
        else
            echo -e "${YELLOW}⚠ Could not send SSM command (instance may not have SSM agent)${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Instance is in $INSTANCE_STATE state${NC}"
    fi
else
    echo -e "${YELLOW}No EC2 instance found in stack (Demo Asterisk may be disabled)${NC}"
fi

echo -e "${GREEN}=== Verification Complete ===${NC}"
echo ""
echo "Manual verification steps:"
echo "1. Check AWS Security Hub for updated findings"
echo "2. Run container vulnerability scans on new images"
echo "3. Test LCA functionality to ensure no regressions"
echo "4. Monitor CloudWatch logs for any errors"
echo ""
echo "Expected package versions after update:"
echo "EC2 Instance (Ubuntu):"
echo "• liburiparser1: 0:0.9.6+dfsg-1ubuntu0.1~esm1"
echo "• libopusfile0: 0:0.9+20170913-1.1ubuntu0.1~esm1"
echo ""
echo "Container Images (Debian):"
echo "• ncurses: 0:6.1+20181013-2+deb10u5"
echo "• gnutls28: 0:3.6.7-4+deb10u12"
echo "• glibc: 0:2.28-10+deb10u3"
echo "• util-linux: 0:2.33.1-0.1+deb10u1"
echo "• tar: 0:1.30+dfsg-6+deb10u1"