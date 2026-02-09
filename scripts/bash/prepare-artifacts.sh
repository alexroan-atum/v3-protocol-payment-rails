#!/usr/bin/env bash

# Pre-production artifacts preparation script
# This script builds optimized contracts and prepares them for npm publishing

set -euo pipefail

echo "🔨 Building optimized contracts..."

# Build with optimized profile (1M optimizer runs + via-ir)
FOUNDRY_PROFILE=optimized forge build

echo "📦 Preparing artifacts directory..."

# Create artifacts directory
mkdir -p artifacts

# Copy optimized ABIs to artifacts (customize based on your contract names)
# Example: cp out-optimized/YourContract.sol/YourContract.json artifacts/

# Copy specific contract ABIs
if [ -d "out-optimized" ]; then
  find out-optimized -name "*.json" -type f ! -path "*/build-info/*" -exec cp {} artifacts/ \;
fi

echo "✨ Formatting artifacts with Prettier..."
bun prettier --write "artifacts/**/*.json"

echo "✅ Artifacts prepared successfully!"
echo "📁 Location: ./artifacts/"
