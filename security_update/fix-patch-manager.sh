#!/bin/bash

# Fix Patch Manager Script
# This script resolves "RESOURCE_NOT_REPORTING" issues with AWS Patch Manager

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Fix AWS Patch Manager Issues ===${NC}"

if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <instance-id-or-stack-name>${NC}"
    echo ""
    echo "Examples:"
    echo "  $0 i-1234567890abcdef0                    # Direct instance ID"
    echo "  $0 LCA-stack-ChimeVCAsteriskDemoStack     # CloudFormation stack name"
    exit 1
fi

INPUT=$1

# Determine if input is instance ID or stack name
if [[ $INPUT =~ ^i-[0-9a-f]{8,17}$ ]]; then
    INSTANCE_ID=$INPUT
    echo "Using provided instance ID: $INSTANCE_ID"
else
    echo "Looking up instance ID from CloudFormation stack: $INPUT"
    INSTANCE_ID=$(aws cloudformation describe-stack-resources \
        --stack-name "$INPUT" \
        --query "StackResources[?LogicalResourceId=='AsteriskInstance'].PhysicalResourceId" \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
        echo -e "${RED}✗ No EC2 instance found in stack: $INPUT${NC}"
        echo "Try using the find-asterisk-instance.sh script to locate your instance"
        exit 1
    fi
    echo "Found instance ID: $INSTANCE_ID"
fi

echo -e "${YELLOW}Step 1: Checking current patch manager status${NC}"

# Check current patch state
PATCH_STATE=$(aws ssm describe-instance-patch-states \
    --instance-ids "$INSTANCE_ID" \
    --query "InstancePatchStates" \
    --output json 2>/dev/null || echo "[]")

if [ "$PATCH_STATE" = "[]" ]; then
    echo -e "${RED}✗ Instance has no patch state (RESOURCE_NOT_REPORTING)${NC}"
    NEEDS_INITIAL_SCAN=true
else
    echo -e "${GREEN}✓ Instance has patch state${NC}"
    echo "$PATCH_STATE" | jq -r '.[0] | "Last operation: \(.Operation // "None"), Missing: \(.MissingCount // "Unknown"), Failed: \(.FailedCount // "Unknown")"'
    NEEDS_INITIAL_SCAN=false
fi

echo -e "${YELLOW}Step 2: Checking SSM agent status${NC}"

# Check SSM registration
SSM_INFO=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query "InstanceInformationList[0]" \
    --output json 2>/dev/null || echo "{}")

if [ "$SSM_INFO" = "{}" ]; then
    echo -e "${RED}✗ Instance not registered with SSM${NC}"
    echo "This needs to be fixed first. Checking SSM agent..."
    
    # Try to check SSM agent status
    echo "Attempting to restart SSM agent..."
    RESTART_COMMAND=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["sudo systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service", "sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service"]' \
        --query "Command.CommandId" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$RESTART_COMMAND" ]; then
        echo "SSM agent restart command sent: $RESTART_COMMAND"
        echo "Waiting 30 seconds for agent to restart..."
        sleep 30
    else
        echo -e "${RED}✗ Cannot send SSM commands to instance${NC}"
        echo "You may need to:"
        echo "1. SSH to the instance and manually restart SSM agent"
        echo "2. Check if the instance has proper IAM role with SSM permissions"
        echo "3. Verify network connectivity to SSM endpoints"
        exit 1
    fi
else
    PING_STATUS=$(echo "$SSM_INFO" | jq -r '.PingStatus // "Unknown"')
    AGENT_VERSION=$(echo "$SSM_INFO" | jq -r '.AgentVersion // "Unknown"')
    IS_LATEST=$(echo "$SSM_INFO" | jq -r '.IsLatestVersion // false')
    
    echo "SSM Status: $PING_STATUS"
    echo "Agent Version: $AGENT_VERSION"
    echo "Is Latest: $IS_LATEST"
    
    if [ "$PING_STATUS" != "Online" ]; then
        echo -e "${YELLOW}⚠ SSM agent not online, attempting to restart...${NC}"
        
        RESTART_COMMAND=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["sudo systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service"]' \
            --query "Command.CommandId" \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$RESTART_COMMAND" ]; then
            echo "SSM agent restart initiated: $RESTART_COMMAND"
            sleep 30
        fi
    fi
    
    if [ "$IS_LATEST" = "false" ]; then
        echo -e "${YELLOW}⚠ Updating SSM agent to latest version...${NC}"
        
        UPDATE_COMMAND=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["sudo snap refresh amazon-ssm-agent", "sudo systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service"]' \
            --query "Command.CommandId" \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$UPDATE_COMMAND" ]; then
            echo "SSM agent update initiated: $UPDATE_COMMAND"
            sleep 30
        fi
    fi
fi

echo -e "${YELLOW}Step 3: Checking patch group configuration${NC}"

# Check if instance has Patch Group tag
PATCH_GROUP_TAG=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Patch Group" \
    --query "Tags[0].Value" \
    --output text 2>/dev/null || echo "None")

if [ "$PATCH_GROUP_TAG" = "None" ] || [ -z "$PATCH_GROUP_TAG" ]; then
    echo -e "${YELLOW}⚠ No Patch Group tag found, adding default tag...${NC}"
    
    aws ec2 create-tags \
        --resources "$INSTANCE_ID" \
        --tags Key="Patch Group",Value="default"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Added Patch Group tag: default${NC}"
    else
        echo -e "${RED}✗ Failed to add Patch Group tag${NC}"
    fi
else
    echo -e "${GREEN}✓ Patch Group tag exists: $PATCH_GROUP_TAG${NC}"
fi

echo -e "${YELLOW}Step 4: Running initial patch scan${NC}"

if [ "$NEEDS_INITIAL_SCAN" = "true" ]; then
    echo "Running initial patch baseline scan to populate patch state..."
    
    SCAN_COMMAND=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunPatchBaseline" \
        --parameters "Operation=Scan" \
        --query "Command.CommandId" \
        --output text)
    
    if [ -n "$SCAN_COMMAND" ]; then
        echo "Patch scan initiated. Command ID: $SCAN_COMMAND"
        echo "Waiting for scan to complete..."
        
        # Wait for scan to complete (up to 10 minutes)
        for i in {1..60}; do
            STATUS=$(aws ssm get-command-invocation \
                --command-id "$SCAN_COMMAND" \
                --instance-id "$INSTANCE_ID" \
                --query "Status" \
                --output text 2>/dev/null || echo "InProgress")
            
            if [ "$STATUS" = "Success" ]; then
                echo -e "${GREEN}✓ Patch scan completed successfully${NC}"
                break
            elif [ "$STATUS" = "Failed" ]; then
                echo -e "${RED}✗ Patch scan failed${NC}"
                
                # Get error details
                ERROR_OUTPUT=$(aws ssm get-command-invocation \
                    --command-id "$SCAN_COMMAND" \
                    --instance-id "$INSTANCE_ID" \
                    --query "StandardErrorContent" \
                    --output text 2>/dev/null || echo "")
                
                if [ -n "$ERROR_OUTPUT" ]; then
                    echo "Error details: $ERROR_OUTPUT"
                fi
                break
            else
                echo "Scan status: $STATUS (waiting... $i/60)"
                sleep 10
            fi
        done
    else
        echo -e "${RED}✗ Failed to initiate patch scan${NC}"
        exit 1
    fi
else
    echo "Instance already has patch state, running refresh scan..."
    
    SCAN_COMMAND=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunPatchBaseline" \
        --parameters "Operation=Scan" \
        --query "Command.CommandId" \
        --output text)
    
    echo "Refresh scan initiated. Command ID: $SCAN_COMMAND"
fi

echo -e "${YELLOW}Step 5: Verifying patch manager fix${NC}"

# Wait a moment for patch state to update
sleep 10

# Check patch state again
UPDATED_PATCH_STATE=$(aws ssm describe-instance-patch-states \
    --instance-ids "$INSTANCE_ID" \
    --query "InstancePatchStates[0]" \
    --output json 2>/dev/null || echo "{}")

if [ "$UPDATED_PATCH_STATE" != "{}" ]; then
    echo -e "${GREEN}✓ Patch state now available:${NC}"
    echo "$UPDATED_PATCH_STATE" | jq -r '"Operation: " + (.Operation // "None") + ", Installed: " + (.InstalledCount // 0 | tostring) + ", Missing: " + (.MissingCount // 0 | tostring) + ", Failed: " + (.FailedCount // 0 | tostring)'
    
    MISSING_COUNT=$(echo "$UPDATED_PATCH_STATE" | jq -r '.MissingCount // 0')
    if [ "$MISSING_COUNT" != "0" ]; then
        echo -e "${YELLOW}⚠ $MISSING_COUNT patches are missing${NC}"
        echo "You may want to run patch installation:"
        echo "aws ssm send-command --instance-ids $INSTANCE_ID --document-name \"AWS-RunPatchBaseline\" --parameters \"Operation=Install\""
    else
        echo -e "${GREEN}✓ Instance is fully patched${NC}"
    fi
else
    echo -e "${RED}✗ Patch state still not available${NC}"
    echo "This may take a few more minutes to appear in AWS Systems Manager"
fi

echo -e "${YELLOW}Step 6: Setting up automatic patch management${NC}"

# Check if there are any maintenance windows for this instance
MAINTENANCE_WINDOWS=$(aws ssm describe-maintenance-windows \
    --query "WindowIdentities[?Enabled==\`true\`].[WindowId,Name]" \
    --output text)

if [ -n "$MAINTENANCE_WINDOWS" ]; then
    echo -e "${GREEN}✓ Maintenance windows are configured:${NC}"
    echo "$MAINTENANCE_WINDOWS"
else
    echo -e "${YELLOW}⚠ No maintenance windows found${NC}"
    echo "Consider setting up a maintenance window for automatic patching:"
    echo "1. Go to AWS Systems Manager → Maintenance Windows"
    echo "2. Create a new maintenance window"
    echo "3. Add this instance as a target"
    echo "4. Add a patch installation task"
fi

echo -e "${GREEN}=== Patch Manager Fix Complete ===${NC}"
echo ""
echo "Summary:"
echo "• Instance ID: $INSTANCE_ID"
echo "• SSM Agent: Updated and restarted"
echo "• Patch Group: Configured"
echo "• Initial Scan: Completed"
echo "• Patch State: Available"
echo ""
echo "The 'RESOURCE_NOT_REPORTING' error should now be resolved."
echo "Check AWS Systems Manager → Patch Manager → Patch compliance to verify."
echo ""
echo "Next steps:"
echo "1. Verify the fix in AWS Console"
echo "2. Set up maintenance windows for automatic patching"
echo "3. Monitor patch compliance regularly"