#!/bin/bash

# Quick Fix for Dependency Issues
# This script fixes the package-lock.json sync issues

set -e

echo "=== Fixing LCA WebSocket Dependencies ==="

cd lca-websocket-transcriber-stack/source/app

echo "1. Removing old package-lock.json..."
rm -f package-lock.json

echo "2. Clearing npm cache..."
npm cache clean --force

echo "3. Installing dependencies with fresh lock file..."
npm install

echo "4. Testing build..."
npm run buildcheck

echo "✓ Dependencies fixed! You can now run the deployment script."

cd ../../..

echo ""
echo "Next steps:"
echo "1. Run: ./security-update-deployment.sh YOUR_STACK_NAME"
echo "2. Or run: cd lca-websocket-transcriber-stack && ./clean-and-build.sh YOUR_STACK_NAME"