#!/bin/bash
# Force rebuild and check contract sizes
# Usage: ./scripts/check-contract-size.sh [contract-name]

set -e

echo "Cleaning build cache..."
forge clean

echo "Building with size report..."
if [ -z "$1" ]; then
    forge build --sizes
else
    forge build --sizes | grep -A 2 "$1"
fi
