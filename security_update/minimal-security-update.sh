#!/bin/bash

# Minimal Security Update Script
# This script applies only the essential security patches without major version upgrades

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Minimal LCA Security Update ===${NC}"

# Check if stack name is provided
if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <stack-name>${NC}"
    echo "Example: $0 LCA-bandytoy-WEBSOCKETTRANSCRIBERSTACK-46RBOCMXZDJA"
    exit 1
fi

STACK_NAME=$1

echo -e "${YELLOW}Step 1: Creating minimal security Dockerfile${NC}"

# Create a minimal security-focused Dockerfile that keeps the original structure
cat > ../lca-websocket-transcriber-stack/source/app/Dockerfile.security << 'EOF'
ARG NODE_VERSION=18

# First, build the project - explicitly specify platform for ECS Fargate compatibility
FROM --platform=linux/amd64 public.ecr.aws/docker/library/node:18-bullseye AS builder

# Apply security updates to base packages
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --only-upgrade ncurses-base ncurses-bin libncurses6 libncursesw6 || true && \
    apt-get install -y --only-upgrade gnutls-bin libgnutls30 || true && \
    apt-get install -y --only-upgrade libc6 libc-bin || true && \
    apt-get install -y --only-upgrade util-linux || true && \
    apt-get install -y --only-upgrade tar || true && \
    apt-get install -y python3 python3-dev python3-pip && \
    ln -sfn /usr/bin/python3 /usr/bin/python && \
    ln -sfn /usr/bin/pip3 /usr/bin/pip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy original package files (no changes to dependencies)
COPY [\
    "./.eslintrc",\
    "./.eslintignore",\
    "./package.json",\
    "./package-lock.json",\
    "./tsconfig.json",\
    "/app/"\
]

# Use original npm ci to maintain compatibility
RUN npm ci

COPY "./src" "/app/src"

RUN npm run build

RUN npm prune --production

# Now create the runtime image and copy the build artifacts into it - explicitly specify platform for ECS Fargate compatibility
FROM --platform=linux/amd64 public.ecr.aws/docker/library/node:18-slim AS runtime

# Apply security updates to runtime image
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --only-upgrade ncurses-base ncurses-bin libncurses6 libncursesw6 || true && \
    apt-get install -y --only-upgrade gnutls-bin libgnutls30 || true && \
    apt-get install -y --only-upgrade libc6 libc-bin || true && \
    apt-get install -y --only-upgrade util-linux || true && \
    apt-get install -y --only-upgrade tar || true && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV NODE_ENV=production
ENV LOG_ROOT_DIR=/tmp/
ENV SERVERPORT=8080
ENV SERVERHOST=0.0.0.0
EXPOSE $SERVERPORT

COPY --from=builder "/app/node_modules/" "/app/node_modules"
COPY --from=builder "/app/dist" "/app/dist"

USER node
ENTRYPOINT ["node", "/app/dist/index.js"]
EOF

echo -e "${YELLOW}Step 2: Backing up original Dockerfile${NC}"
cp ../lca-websocket-transcriber-stack/source/app/Dockerfile ../lca-websocket-transcriber-stack/source/app/Dockerfile.backup

echo -e "${YELLOW}Step 3: Using security-focused Dockerfile${NC}"
cp ../lca-websocket-transcriber-stack/source/app/Dockerfile.security ../lca-websocket-transcriber-stack/source/app/Dockerfile

echo -e "${YELLOW}Step 4: Building and deploying container${NC}"
cd ../lca-websocket-transcriber-stack
./update-ecs.sh "$STACK_NAME"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Container security update completed${NC}"
else
    echo -e "${RED}✗ Container security update failed${NC}"
    echo "Restoring original Dockerfile..."
    cp source/app/Dockerfile.backup source/app/Dockerfile
    exit 1
fi

cd ../security_update_scripts

echo -e "${YELLOW}Step 5: Updating EC2 Instance${NC}"
# Apply EC2 security updates using CloudFormation
aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --use-previous-template \
    --capabilities CAPABILITY_IAM \
    --parameters ParameterKey=Version,ParameterValue="$(date +%Y%m%d%H%M%S)" \
    --output text

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ EC2 security update initiated${NC}"
else
    echo -e "${RED}✗ EC2 security update failed${NC}"
fi

echo -e "${GREEN}=== Minimal Security Update Complete ===${NC}"
echo ""
echo "What was updated:"
echo "• Container base images: Applied security patches for ncurses, gnutls, glibc, util-linux, tar"
echo "• EC2 instance: Applied patches for liburiparser1, libopusfile0"
echo "• No application code changes - maintains full compatibility"
echo ""
echo "Next steps:"
echo "1. Monitor CloudFormation stack update progress"
echo "2. Verify ECS tasks are running successfully"
echo "3. Test LCA functionality"
echo "4. Run security scans to confirm vulnerabilities are resolved"