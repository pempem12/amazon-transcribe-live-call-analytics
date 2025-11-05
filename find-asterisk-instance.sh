#!/bin/bash

# Find Asterisk Instance Script
# This script helps locate the Asterisk EC2 instance across all stacks

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Finding Asterisk EC2 Instance ===${NC}"

if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <main-stack-name>${NC}"
    echo "Example: $0 LCA-bandytoy-WEBSOCKETTRANSCRIBERSTACK-46RBOCMXZDJA"
    exit 1
fi

MAIN_STACK_NAME=$1

echo -e "${YELLOW}Step 1: Checking main stack for nested stacks${NC}"

# Look for nested stacks that might contain the Asterisk instance
NESTED_STACKS=$(aws cloudformation describe-stack-resources \
    --stack-name "$MAIN_STACK_NAME" \
    --query "StackResources[?ResourceType=='AWS::CloudFormation::Stack'].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")

if [ -n "$NESTED_STACKS" ]; then
    echo "Found nested stacks:"
    for stack in $NESTED_STACKS; do
        echo "  - $stack"
    done
    echo ""
else
    echo "No nested stacks found in main stack"
fi

echo -e "${YELLOW}Step 2: Searching for Asterisk instances across all stacks${NC}"

# Search in main stack first
echo "Checking main stack: $MAIN_STACK_NAME"
INSTANCE_ID=$(aws cloudformation describe-stack-resources \
    --stack-name "$MAIN_STACK_NAME" \
    --query "StackResources[?LogicalResourceId=='AsteriskInstance'].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    echo -e "${GREEN}✓ Found Asterisk instance in main stack: $INSTANCE_ID${NC}"
    FOUND_STACK="$MAIN_STACK_NAME"
else
    echo "No Asterisk instance in main stack"
    
    # Search in nested stacks
    if [ -n "$NESTED_STACKS" ]; then
        for stack in $NESTED_STACKS; do
            echo "Checking nested stack: $stack"
            INSTANCE_ID=$(aws cloudformation describe-stack-resources \
                --stack-name "$stack" \
                --query "StackResources[?LogicalResourceId=='AsteriskInstance'].PhysicalResourceId" \
                --output text 2>/dev/null || echo "")
            
            if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
                echo -e "${GREEN}✓ Found Asterisk instance in nested stack: $INSTANCE_ID${NC}"
                FOUND_STACK="$stack"
                break
            else
                echo "No Asterisk instance in $stack"
            fi
        done
    fi
fi

# If still not found, search all EC2 instances with Asterisk in the name
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    echo -e "${YELLOW}Step 3: Searching all EC2 instances for Asterisk servers${NC}"
    
    ASTERISK_INSTANCES=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=*Asterisk*" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
        --query "Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key=='Name'].Value|[0]]" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$ASTERISK_INSTANCES" ]; then
        echo "Found EC2 instances with 'Asterisk' in name:"
        echo "$ASTERISK_INSTANCES" | while read instance_id state name; do
            echo "  - Instance: $instance_id, State: $state, Name: $name"
        done
        
        # Get the first running instance
        INSTANCE_ID=$(echo "$ASTERISK_INSTANCES" | grep "running" | head -1 | awk '{print $1}')
        if [ -n "$INSTANCE_ID" ]; then
            echo -e "${GREEN}✓ Using running Asterisk instance: $INSTANCE_ID${NC}"
        fi
    else
        echo "No EC2 instances found with 'Asterisk' in the name"
    fi
fi

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    echo -e "${YELLOW}Step 4: Instance Details${NC}"
    
    # Get detailed instance information
    INSTANCE_INFO=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].[InstanceType,State.Name,LaunchTime,PublicIpAddress,PrivateIpAddress,Tags[?Key=='Name'].Value|[0]]" \
        --output text)
    
    echo "Instance Details:"
    echo "$INSTANCE_INFO" | while read instance_type state launch_time public_ip private_ip name; do
        echo "  - Instance ID: $INSTANCE_ID"
        echo "  - Name: $name"
        echo "  - Type: $instance_type"
        echo "  - State: $state"
        echo "  - Launch Time: $launch_time"
        echo "  - Public IP: $public_ip"
        echo "  - Private IP: $private_ip"
        if [ -n "$FOUND_STACK" ]; then
            echo "  - CloudFormation Stack: $FOUND_STACK"
        fi
    done
    
    echo -e "${YELLOW}Step 5: Checking for security vulnerabilities${NC}"
    
    # Try to check package versions via SSM
    echo "Attempting to check current package versions..."
    COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["dpkg -l | grep -E \"liburiparser1|libopusfile0\" | awk \"{print \\$2, \\$3}\""]' \
        --query "Command.CommandId" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$COMMAND_ID" ]; then
        echo "SSM command sent. Command ID: $COMMAND_ID"
        echo "Waiting for results..."
        sleep 5
        
        OUTPUT=$(aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --query "StandardOutputContent" \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$OUTPUT" ]; then
            echo "Current package versions:"
            echo "$OUTPUT"
        else
            echo "Could not retrieve package versions (command may still be running)"
        fi
    else
        echo "Could not send SSM command (instance may not have SSM agent)"
    fi
    
    echo ""
    echo -e "${GREEN}=== Next Steps ===${NC}"
    echo "To update this instance with security patches, you can:"
    echo ""
    echo "1. Update via SSM (if SSM agent is available):"
    echo "   aws ssm send-command \\"
    echo "     --instance-ids $INSTANCE_ID \\"
    echo "     --document-name \"AWS-RunShellScript\" \\"
    echo "     --parameters 'commands=[\"sudo apt-get update\", \"sudo apt-get upgrade -y\", \"sudo apt-get install -y --only-upgrade liburiparser1 libopusfile0\"]'"
    echo ""
    if [ -n "$FOUND_STACK" ]; then
        echo "2. Update via CloudFormation stack:"
        echo "   aws cloudformation update-stack \\"
        echo "     --stack-name $FOUND_STACK \\"
        echo "     --use-previous-template \\"
        echo "     --capabilities CAPABILITY_IAM \\"
        echo "     --parameters ParameterKey=Version,ParameterValue=\"\$(date +%Y%m%d%H%M%S)\""
    fi
    echo ""
    echo "3. Manual SSH access (if you have the key pair):"
    echo "   ssh -i your-key.pem ubuntu@$public_ip"
    echo "   sudo apt-get update && sudo apt-get upgrade -y"
    echo "   sudo apt-get install -y --only-upgrade liburiparser1 libopusfile0"
    
else
    echo -e "${RED}✗ No Asterisk EC2 instance found${NC}"
    echo ""
    echo "This could mean:"
    echo "1. The Demo Asterisk PBX Server option was not enabled in your LCA deployment"
    echo "2. The instance is in a different AWS region"
    echo "3. The instance has been terminated"
    echo ""
    echo "To check if Demo Asterisk is enabled, look at your main stack parameters:"
    echo "aws cloudformation describe-stacks --stack-name $MAIN_STACK_NAME --query \"Stacks[0].Parameters[?ParameterKey=='CallAudioSource'].ParameterValue\" --output text"
fi