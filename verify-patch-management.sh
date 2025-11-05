#!/bin/bash

# Verify Patch Management Setup Script
# This script verifies that patch management is properly configured for LCA deployments

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== LCA Patch Management Verification ===${NC}"

if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <stack-name>${NC}"
    echo "Example: $0 LCA-bandytoy-CHIMEVCSTACK-GQ94GIFDGR8M-ChimeVCAsteriskDemoStack-15LOSDG3GO1SM"
    exit 1
fi

STACK_NAME=$1

echo -e "${YELLOW}Step 1: Finding Asterisk instance${NC}"

# Find the instance
INSTANCE_ID=$(aws cloudformation describe-stack-resources \
    --stack-name "$STACK_NAME" \
    --query "StackResources[?LogicalResourceId=='AsteriskInstance'].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    echo -e "${RED}✗ No Asterisk instance found in stack${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found instance: $INSTANCE_ID${NC}"

echo -e "${YELLOW}Step 2: Checking SSM registration${NC}"

# Check SSM registration
SSM_INFO=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0].[PingStatus,AgentVersion,IsLatestVersion]" \
    --output text 2>/dev/null || echo "")

if [ -n "$SSM_INFO" ]; then
    echo "$SSM_INFO" | while read ping_status agent_version is_latest; do
        if [ "$ping_status" = "Online" ]; then
            echo -e "${GREEN}✓ SSM agent online (version: $agent_version)${NC}"
            if [ "$is_latest" = "False" ]; then
                echo -e "${YELLOW}⚠ Agent version is not latest - consider updating${NC}"
            fi
        else
            echo -e "${RED}✗ SSM agent not online (status: $ping_status)${NC}"
        fi
    done
else
    echo -e "${RED}✗ Instance not registered with SSM${NC}"
    exit 1
fi

echo -e "${YELLOW}Step 3: Checking patch baseline configuration${NC}"

# Check patch baselines
PATCH_BASELINES=$(aws ssm describe-patch-baselines \
    --filters "Key=OWNER,Values=Self" \
    --query "BaselineIdentities[?contains(BaselineName, '$STACK_NAME')].[BaselineId,BaselineName]" \
    --output text)

if [ -n "$PATCH_BASELINES" ]; then
    echo -e "${GREEN}✓ Custom patch baseline found:${NC}"
    echo "$PATCH_BASELINES"
else
    echo -e "${YELLOW}⚠ No custom patch baseline found - using default${NC}"
fi

echo -e "${YELLOW}Step 4: Checking patch state${NC}"

# Check patch state
PATCH_STATE=$(aws ssm describe-instance-patch-states \
    --instance-ids "$INSTANCE_ID" \
    --query "InstancePatchStates[0].[Operation,OperationEndTime,InstalledCount,MissingCount,FailedCount]" \
    --output text 2>/dev/null || echo "")

if [ -n "$PATCH_STATE" ] && [ "$PATCH_STATE" != "None" ]; then
    echo -e "${GREEN}✓ Patch state available:${NC}"
    echo "$PATCH_STATE" | while read operation end_time installed missing failed; do
        echo "  Last operation: $operation"
        echo "  Completed: $end_time"
        echo "  Installed patches: $installed"
        echo "  Missing patches: $missing"
        echo "  Failed patches: $failed"
        
        if [ "$missing" = "0" ] && [ "$failed" = "0" ]; then
            echo -e "${GREEN}  ✓ Instance is fully patched${NC}"
        elif [ "$missing" != "0" ]; then
            echo -e "${YELLOW}  ⚠ $missing patches missing${NC}"
        fi
        
        if [ "$failed" != "0" ]; then
            echo -e "${RED}  ✗ $failed patches failed to install${NC}"
        fi
    done
else
    echo -e "${YELLOW}⚠ No patch state found - running initial scan...${NC}"
    
    # Run initial scan
    COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunPatchBaseline" \
        --parameters "Operation=Scan" \
        --query "Command.CommandId" \
        --output text)
    
    echo "Initial patch scan initiated. Command ID: $COMMAND_ID"
    echo "Run this script again in 5-10 minutes to see results."
fi

echo -e "${YELLOW}Step 5: Checking maintenance windows${NC}"

# Check maintenance windows
MAINTENANCE_WINDOWS=$(aws ssm describe-maintenance-windows \
    --filters "Key=Name,Values=${STACK_NAME}*" \
    --query "WindowIdentities[*].[WindowId,Name,Enabled,NextExecutionTime]" \
    --output text)

if [ -n "$MAINTENANCE_WINDOWS" ]; then
    echo -e "${GREEN}✓ Maintenance windows configured:${NC}"
    echo "$MAINTENANCE_WINDOWS" | while read window_id name enabled next_execution; do
        echo "  Window: $name ($window_id)"
        echo "  Enabled: $enabled"
        echo "  Next execution: $next_execution"
    done
else
    echo -e "${YELLOW}⚠ No maintenance windows found${NC}"
fi

echo -e "${YELLOW}Step 6: Checking instance tags${NC}"

# Check patch group tag
PATCH_GROUP_TAG=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Patch Group" \
    --query "Tags[0].Value" \
    --output text 2>/dev/null || echo "")

if [ -n "$PATCH_GROUP_TAG" ] && [ "$PATCH_GROUP_TAG" != "None" ]; then
    echo -e "${GREEN}✓ Patch Group tag: $PATCH_GROUP_TAG${NC}"
else
    echo -e "${YELLOW}⚠ No Patch Group tag found${NC}"
    echo "Consider adding: aws ec2 create-tags --resources $INSTANCE_ID --tags Key='Patch Group',Value='default'"
fi

echo -e "${GREEN}=== Verification Complete ===${NC}"
echo ""
echo "Summary:"
echo "• Instance ID: $INSTANCE_ID"
echo "• SSM Status: Check output above"
echo "• Patch Management: Check output above"
echo ""
echo "If any issues were found, they should be resolved in future deployments with the updated CloudFormation template."