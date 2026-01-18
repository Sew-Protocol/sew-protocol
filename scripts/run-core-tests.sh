#!/bin/bash
# Script to run only core escrow tests (excluding decentralized dispute resolution tests)

set -e

echo "=========================================="
echo "Core Escrow Tests Only"
echo "=========================================="
echo ""
echo "Running tests for core escrow functionality..."
echo "Excluding: decentralized-resolution-module, governance, migrated tests"
echo ""

# Use --match-path to match only core test files
# This excludes:
# - test/foundry/decentralized-resolution-module/*
# - test/foundry/governance/*
# - test/foundry/migrated/*
# - test/foundry/modules/*
# - test/foundry/token/*
# - test/foundry/libraries/*

forge test \
    --match-path "test/foundry/core/*.t.sol" \
    -vv

echo ""
echo "=========================================="
echo "Core tests complete!"
echo "=========================================="
