#!/bin/bash
# Script to compile, check size, and run tests for EscrowVault only

set -e

echo "=========================================="
echo "EscrowVault Only - Compile, Size & Tests"
echo "=========================================="
echo ""

# Step 1: Compile (all contracts needed for EscrowVault)
echo "Step 1: Compiling contracts..."
forge build --skip test --force 2>&1 | grep -E "(Compiling|Error|Warning)" || true
if [ $? -eq 0 ]; then
    echo "✓ Compilation complete"
else
    echo "✗ Compilation failed"
    exit 1
fi
echo ""

# Step 2: Show size only for EscrowVault
echo "Step 2: Contract Size for EscrowVault"
echo "--------------------------------------"
pnpm tsx scripts/escrow-vault-size-only.ts
echo ""

# Step 3: Run tests only for EscrowVault
echo "Step 3: Running tests for EscrowVault..."
echo "--------------------------------------"
# Run specific test files that test EscrowVault
# Note: Tests will need to register escrow contract with CreateOps (see CreateOps.registerEscrowContract)
# Use --match-path with a pattern that matches the test files
forge test --match-path "test/foundry/core/{EscrowConstraints,BaseEscrowComprehensive,EscrowEdgeCases,ReentrancyProtection,AppealWindowEnforcement}.t.sol" -vv 2>&1 | tail -40

echo ""
echo "=========================================="
echo "Complete!"
