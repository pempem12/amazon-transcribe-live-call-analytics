#!/bin/bash

# Fix Platform Architecture Script
# This script rebuilds the Docker image with the correct platform for ECS Fargate

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Fixing Platform Architecture Issue ===${NC}"

# Check if stack name is provided
if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <stack-name>${NC}"
    echo "Example: $0 LCA-bandytoy-WEBSOCKETTRANSCRIBERSTACK-46RBOCMXZDJA"
    exit 1
fi

STACK_NAME=$1

echo -e "${YELLOW}Issue: ECS Fargate tasks expect linux/amd64 platform${NC}"
echo -e "${YELLOW}Solution: Rebuild Docker image with explicit platform specification${NC}"
echo ""

echo -e "${YELLOW}Step 1: Checking Docker buildx support${NC}"
if ! docker buildx version > /dev/null 2>&1; then
    echo -e "${YELLOW}Docker buildx not available, using standard build with platform flag${NC}"
else
    echo -e "${GREEN}✓ Docker buildx available${NC}"
fi

echo -e "${YELLOW}Step 2: Rebuilding container image for linux/amd64${NC}"
cd ../lca-websocket-transcriber-stack

# Run the updated build script
./update-ecs.sh "$STACK_NAME"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Container rebuilt and deployed successfully${NC}"
else
    echo -e "${RED}✗ Container rebuild failed${NC}"
    exit 1
fi

cd ../security_update_scripts

echo -e "${YELLOW}Step 3: Monitoring ECS service deployment${NC}"
echo "Checking ECS service status..."

# Get cluster and service names
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
    echo "Cluster: $CLUSTER_NAME"
    echo "Service: $SERVICE_NAME"
    
    echo "Waiting for service to stabilize..."
    aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" || echo "Wait timeout - check manually"
    
    # Check final status
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
    
    echo "Service status: $RUNNING_COUNT/$DESIRED_COUNT tasks running"
    
    if [ "$RUNNING_COUNT" = "$DESIRED_COUNT" ] && [ "$RUNNING_COUNT" != "0" ]; then
        echo -e "${GREEN}✓ ECS service is healthy${NC}"
    else
        echo -e "${YELLOW}⚠ Service may still be deploying or has issues${NC}"
        echo "Check ECS console for detailed task status"
    fi
else
    echo -e "${YELLOW}Could not retrieve ECS cluster/service information${NC}"
fi

echo -e "${GREEN}=== Platform Architecture Fix Complete ===${NC}"
echo ""
echo "What was fixed:"
echo "• Docker images now built explicitly for linux/amd64 platform"
echo "• ECS Fargate tasks should now be able to pull and run the images"
echo "• Platform mismatch error should be resolved"
echo ""
echo "If tasks are still failing:"
echo "1. Check ECS console for detailed error messages"
echo "2. Verify the new task definition is using the updated image"
echo "3. Check CloudWatch logs for any application errors"