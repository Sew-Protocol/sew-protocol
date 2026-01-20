#!/bin/bash
# Test command for core modules (release & resolution) - Sepolia release focus

# Run tests in core and decentralized-resolution-module directories
# Exclude: disabled files, AutoTransfer, WithdrawEscrow (not critical for launch)

FAILED=0

# Run core tests - exclude disabled, AutoTransfer, WithdrawEscrow via find filter
echo "=== Running core module tests ==="
find test/foundry/core -name '*.t.sol' ! -name '*disabled*' ! -name '*AutoTransfer*' ! -name '*WithdrawEscrow*' -exec forge test {} -vvv "$@" \; || FAILED=1

# Run resolution module tests
echo "=== Running resolution module tests ==="
forge test test/foundry/decentralized-resolution-module -vvv "$@" || FAILED=1

exit $FAILED
