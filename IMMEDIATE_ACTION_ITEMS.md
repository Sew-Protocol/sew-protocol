# Immediate Action Items - Phase 4 Unblock

**Status**: 🔴 BLOCKED on CreateOps Issue  
**Priority**: HIGH (blocks yield testing)  
**Estimated Time**: 1-2 hours to fix

---

## What's Blocking Phase 4

New escrow creation is failing with `execution reverted`. The exact reason is unknown.

**Evidence**:
- 11 escrows exist (it worked before)
- New escrow attempts all fail
- Other operations (cancel, release) still work
- Issue happens even with `yieldPreset=0` (no Aave)

---

## Root Cause Candidates (Ranked by Likelihood)

### 1. CreateOps Lost Module Reference (HIGH)
**What to check**:
```bash
# Check if generationModule is zeroed/missing
cast storage 0xBC60481020457CAC819B6938396a1002B0518f34 --rpc-url baseSepolia
# Look for the slot that stores generationModule address
```

### 2. Deployer Lost ROLE_ESCROW_CONTRACT (MEDIUM)
**What to check**:
```bash
# Check if deployer has the required role
cast call 0xBC60481020457CAC819B6938396a1002B0518f34 \
  "hasRole(bytes32,address)" \
  --rpc-url baseSepolia
```

### 3. CreateOps Guard/Lock Stuck (LOW)
**What to check**:
```bash
# Run with trace to see exact revert point
forge test test/foundry/testnet/Phase0BaseSepoliaFork.t.sol -vvv --trace
```

---

## Recommended Debug Path

### Step 1: Get Exact Revert Reason (5 min)
```bash
# Run Phase 0 with verbose output to see exact failure point
cd /home/user/Code/hardhat-deploy-hybrid-aave

# Option A: Foundry trace
forge test test/foundry/testnet/Phase0BaseSepoliaFork.t.sol \
  -vvv --trace -k "createEscrow" 2>&1 | tee phase0-trace.log

# Option B: Hardhat trace (if available)
pnpm hardhat run scripts/testnet/phase4-basic-escrow.ts \
  --network baseSepolia 2>&1 | tee escrow-trace.log
```

### Step 2: Inspect CreateOps State (5 min)
```bash
# Check storage at suspected slots
cast storage 0xBC60481020457CAC819B6938396a1002B0518f34 \
  --rpc-url https://sepolia.base.org \
  0:10 # Check first 10 storage slots

# Get current bytecode size
cast code 0xBC60481020457CAC819B6938396a1002B0518f34 \
  --rpc-url https://sepolia.base.org | wc -c
```

### Step 3: Validate Module Registry (5 min)
```bash
# Check if AaveYieldModule is registered
cast call 0x1B152685Fb8268d7eb4F292524d86661dCFEEdE6 \
  "getModule(address)" \
  0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01 \
  --rpc-url https://sepolia.base.org
```

### Step 4: Check Role Permissions (5 min)
```bash
# Get ROLE_ESCROW_CONTRACT from contract
# Then check if deployer has it
DEPLOYER_ADDR="0xE8d7Fbd5Db3ad910370Be315f21D4596ed45122f"
ROLE_HASH="<obtain from contract>"

cast call 0xBC60481020457CAC819B6938396a1002B0518f34 \
  "hasRole(bytes32,address)" \
  "$ROLE_HASH" "$DEPLOYER_ADDR" \
  --rpc-url https://sepolia.base.org
```

---

## If Issue is Found

### If CreateOps Module Reference Missing
**Fix**: Re-initialize CreateOps with module reference
```bash
# Option 1: Run initialization script
pnpm hardhat run deploy/75_aave_yield_module.ts --network baseSepolia

# Option 2: Manual role grant
pnpm hardhat run scripts/manual-setup/grant-createops-module.ts --network baseSepolia
```

### If Deployer Missing Role
**Fix**: Grant ROLE_ESCROW_CONTRACT to deployer
```bash
# Create role grant script
pnpm hardhat run scripts/manual-setup/grant-deployer-role.ts --network baseSepolia
```

### If Guard/Lock Stuck
**Fix**: Reset reentrancy guard or unlock contract
```bash
# This might require access to Timelock/Governor
# Check EscrowGovernanceTimelock for queue/execute
pnpm hardhat run scripts/manual-setup/reset-guard.ts --network baseSepolia
```

---

## Verification After Fix

### Step 1: Test Basic Escrow Creation
```bash
# Run phase4-basic-escrow.ts
pnpm hardhat run scripts/testnet/phase4-basic-escrow.ts --network baseSepolia

# Expected output:
# ✅ Escrow created
# Workflow ID: <number>
```

### Step 2: Run Phase 0 Health Check
```bash
# Run full health check
pnpm hardhat run scripts/testnet/phase0-base-sepolia-health.ts --network baseSepolia

# Expected output:
# ✅ Phase 0 health check succeeded
```

### Step 3: Proceed to Phase 4 Yield Testing
```bash
# Run yield test setup
pnpm hardhat run scripts/testnet/phase4-yield-testing.ts --network baseSepolia

# Then monitor yield daily
pnpm hardhat run scripts/testnet/phase4-yield-tracking.ts --network baseSepolia <workflowId>
```

---

## Files That Will Help Debug

- `DEPLOYMENT_ISSUE_CRITICAL.md` - Detailed issue analysis
- `SESSION_SUMMARY_PHASE_4.md` - Complete investigation results  
- `scripts/testnet/diagnose-createops.ts` - CreateOps state inspector
- `scripts/testnet/phase4-basic-escrow.ts` - Minimal escrow creation test

---

## Key Contact Points

**Issue Summary**: New escrows revert, but 11 existing escrows prove it worked

**Addresses**:
- EscrowVault: `0x13b8b7572c72b46879662BFEA53851cBeD3bC47a`
- CreateOps: `0xBC60481020457CAC819B6938396a1002B0518f34`
- AaveYieldModule: `0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01`

**RPC**: https://sepolia.base.org

---

## Timeline

- **Debug**: 15-20 minutes (with commands above)
- **Fix**: 15-30 minutes (once cause identified)
- **Verify**: 5-10 minutes (run tests)
- **Total**: ~45 minutes to 1 hour

**Full Phase 4 after fix**: 7-30 days (yield monitoring)

---

**Next Action**: Run Step 1 above to identify exact revert reason

