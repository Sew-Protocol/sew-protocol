#!/bin/bash
# Script to update all test files that create EscrowVault instances
# Adds ModuleManagementContract deployment and updates constructor calls

set -e

echo "Updating test files to include ModuleManagementContract..."

# Find all test files that create EscrowVault
FILES=$(find test -name "*.sol" -exec grep -l "new EscrowVault(" {} \;)

for file in $FILES; do
    echo "Processing $file..."
    
    # Check if file already has ModuleManagementContract
    if grep -q "ModuleManagementContract" "$file"; then
        echo "  Already updated, skipping..."
        continue
    fi
    
    # Add import if not present
    if ! grep -q "import.*ModuleManagementContract" "$file"; then
        # Find the last import line
        LAST_IMPORT=$(grep -n "^import" "$file" | tail -1 | cut -d: -f1)
        if [ -n "$LAST_IMPORT" ]; then
            sed -i "${LAST_IMPORT}a import '../../../contracts/core/ModuleManagementContract.sol';" "$file"
        fi
    fi
    
    # Add variable declaration (find a good spot after other contract declarations)
    if ! grep -q "ModuleManagementContract" "$file" || ! grep -q "moduleManagement" "$file"; then
        # Find line with "DisputeOps" or "YieldOps" declaration
        DECL_LINE=$(grep -n "DisputeOps\|YieldOps" "$file" | head -1 | cut -d: -f1)
        if [ -n "$DECL_LINE" ]; then
            sed -i "${DECL_LINE}a     ModuleManagementContract public moduleManagement;" "$file"
        fi
    fi
    
    # Update constructor call - find the pattern and replace
    # Pattern: new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps));
    # Replace with: new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
    
    # First, add moduleManagement deployment before EscrowVault
    ESCROW_LINE=$(grep -n "new EscrowVault(" "$file" | head -1 | cut -d: -f1)
    if [ -n "$ESCROW_LINE" ]; then
        # Check if moduleManagement is already deployed before this line
        if ! sed -n "1,${ESCROW_LINE}p" "$file" | grep -q "moduleManagement = new"; then
            # Add deployment before EscrowVault
            sed -i "$((ESCROW_LINE-1))a         moduleManagement = new ModuleManagementContract(address(this));" "$file"
        fi
        
        # Update constructor call
        sed -i "s/new EscrowVault(\([^,]*\), \([^,]*\), \([^,]*\), \([^)]*\));/new EscrowVault(\1, \2, \3, \4, address(moduleManagement));/g" "$file"
        
        # Add registration after EscrowVault deployment
        sed -i "${ESCROW_LINE}a         moduleManagement.registerEscrowContract(address(vault));" "$file" || \
        sed -i "${ESCROW_LINE}a         moduleManagement.registerEscrowContract(address(escrow));" "$file"
    fi
done

echo "Done! Please review changes before committing."
