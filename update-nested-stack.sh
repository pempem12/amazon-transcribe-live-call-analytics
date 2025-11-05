#!/bin/bash

# Update Nested Stack Script
# This script properly updates nested CloudFormation stacks

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Nested Stack Update ===${NC}"

if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <nested-stack-name>${NC}"
    echo "Example: $0 LCA-bandytoy-CHIMEVCSTACK-GQ94GIFDGR8M-ChimeVCAsteriskDemoStack-15LOSDG3GO1SM"
    exit 1
fi

NESTED_STACK_NAME=$1

echo -e "${YELLOW}Step 1: Getting stack information${NC}"

# Get stack parameters
STACK_PARAMS=$(aws cloudformation describe-stacks \
    --stack-name "$NESTED_STACK_NAME" \
    --query "Stacks[0].Parameters" \
    --output json)

echo "Current stack parameters:"
echo "$STACK_PARAMS" | jq -r '.[] | "\(.ParameterKey): \(.ParameterValue)"'

echo -e "${YELLOW}Step 2: Preparing parameter update${NC}"

# Convert parameters to update format, updating the Version parameter
PARAM_STRING=""
while read -r key value; do
    if [ "$key" = "Version" ]; then
        # Update version to current timestamp
        NEW_VERSION=$(date +%Y%m%d%H%M%S)
        PARAM_STRING="${PARAM_STRING}ParameterKey=${key},ParameterValue=${NEW_VERSION} "
        echo "Updating Version parameter: $value -> $NEW_VERSION"
    else
        PARAM_STRING="${PARAM_STRING}ParameterKey=${key},ParameterValue=${value} "
    fi
done < <(echo "$STACK_PARAMS" | jq -r '.[] | "\(.ParameterKey) \(.ParameterValue)"')

echo -e "${YELLOW}Step 3: Updating nested stack${NC}"

# Update the nested stack
aws cloudformation update-stack \
    --stack-name "$NESTED_STACK_NAME" \
    --use-previous-template \
    --capabilities CAPABILITY_IAM \
    --parameters $PARAM_STRING

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Nested stack update initiated successfully${NC}"
    
    echo -e "${YELLOW}Step 4: Monitoring update progress${NC}"
    echo "You can monitor progress with:"
    echo "aws cloudformation describe-stack-events --stack-name $NESTED_STACK_NAME"
    
    # Optional: Wait for completion
    read -p "Do you want to wait for the stack update to complete? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Waiting for stack update to complete..."
        aws cloudformation wait stack-update-complete --stack-name "$NESTED_STACK_NAME"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Stack update completed successfully${NC}"
            
            # Get new instance information
            NEW_INSTANCE_ID=$(aws cloudformation describe-stack-resources \
                --stack-name "$NESTED_STACK_NAME" \
                --query "StackResources[?LogicalResourceId=='AsteriskInstance'].PhysicalResourceId" \
                --output text)
            
            if [ -n "$NEW_INSTANCE_ID" ]; then
                echo "New instance ID: $NEW_INSTANCE_ID"
                
                # Get instance details
                INSTANCE_INFO=$(aws ec2 describe-instances \
                    --instance-ids "$NEW_INSTANCE_ID" \
                    --query "Reservations[0].Instances[0].[State.Name,PublicIpAddress,LaunchTime]" \
                    --output text)
                
                echo "New instance details: $INSTANCE_INFO"
            fi
        else
            echo -e "${RED}✗ Stack update failed or timed out${NC}"
        fi
    fi
else
    echo -e "${RED}✗ Failed to initiate stack update${NC}"
    exit 1
fi

echo -e "${GREEN}=== Update Complete ===${NC}"