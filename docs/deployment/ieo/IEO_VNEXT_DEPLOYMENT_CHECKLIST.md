# IEO vNext Deployment Checklist

**Release:** IEO vNext (Base Sepolia Testnet)  
**Target Deployment:** 2026-01-22 (tomorrow)  
**Branch:** `release/base-sepolia-ieo` (merged with `next/aave`)  
**Additional Tests:** `testnet/validation` branch (to be merged post-deployment)  
**Network:** Base Sepolia (chainId 84532)

---

## Pre-Deployment Checklist

### Code Verification
- [ ] **Verify branch**: Ensure you're on `release/base-sepolia-ieo` branch (merged with `next/aave`)
  ```bash
  git branch --show-current
  # Should show: release/base-sepolia-ieo
  ```

- [ ] **Verify Aave integration**: Confirm `next/aave` changes are merged
  ```bash
  git log --oneline --all --grep="aave\|Aave" | head -5
  # Should show Aave-related commits
  ```
  ```bash
  git branch --show-current
  # Should show: release/base-sepolia-ieo
  ```

- [ ] **Check contract sizes**: Verify contracts are under 24KB limit (with Aave optimizations)
  ```bash
  export SOLC_RUNS=200
  forge build --sizes | grep -E "(EscrowVault|EscrowableERC20)"
  # EscrowVault should be < 24KB (approaching limit with Aave integration)
  # EscrowableERC20 should be < 24KB (or close)
  # Note: Size optimizations from next/aave branch should be applied
  ```

- [ ] **Run tests**: Ensure all tests pass
  ```bash
  pnpm test
  forge test
  ```

### Environment Setup
- [ ] **Verify RPC connectivity**: Test connection to Base Sepolia
  ```bash
  pnpm hardhat console --network baseSepolia
  # Test: await hre.ethers.provider.getBlockNumber()
  ```

- [ ] **Check deployer balance**: Ensure deployer has sufficient ETH for gas
  ```bash
  pnpm hardhat console --network baseSepolia
  # const { getNamedAccounts } = hre;
  # const { deployer } = await getNamedAccounts();
  # const bal = await hre.ethers.provider.getBalance(deployer);
  # console.log("Balance:", hre.ethers.formatEther(bal), "ETH");
  ```

- [ ] **Verify environment variables**: Check `.env` file has required variables
  - [ ] `RPC_BASE_SEPOLIA` set
  - [ ] `SEPOLIA_DEPLOY_KEY` set (for core escrow deployment)
  - [ ] `PROPOSAL_THRESHOLD=50000000000000000000000` (50k tokens)
  - [ ] Governance addresses (if reusing existing governance)

### Deployment Decision: Reuse vs. Redeploy

#### Contracts to REUSE (same addresses)
- [ ] **Ops contracts**: `CreateOps`, `SettlementOps`, `DisputeOps`, `YieldOps`, `BondCollector`
  - **Reason**: No changes in vNext, can reuse existing addresses
  - **Action**: Skip deployment of these contracts

- [ ] **Governance infrastructure**: `SewToken`, `TimelockController`, `GovGovernor`
  - **Reason**: No changes in vNext, governance remains unchanged
  - **Action**: Skip deployment, use existing addresses

- [ ] **Admin contracts**: `EscrowAdminContract`, `ModuleManagementContract`
  - **Reason**: No changes in vNext
  - **Action**: Skip deployment, use existing addresses

- [ ] **Modules**: `DefaultReleaseStrategy` (if already deployed)
  - **Reason**: No changes in vNext
  - **Action**: Skip deployment if already exists

#### Contracts to REDEPLOY (new addresses)
- [ ] **EscrowVault**: Must redeploy (new security fixes, module swap wrappers)
  - **Reason**: Contains security hardening and module swap restoration
  - **Action**: Deploy new instance, will get new address

- [ ] **EscrowableERC20** (optional): Deploy if needed for testing
  - **Reason**: Contains same security fixes, module swap wrappers, and Aave hooks
  - **Action**: Deploy if required, otherwise skip

- [ ] **AaveYieldGenerationModule** (optional): Deploy if yield testing needed
  - **Reason**: Aave integration is ready, can be deployed and swapped in post-deployment
  - **Action**: Deploy if yield testing is required, otherwise can be deployed later

---

## Deployment Steps

### Step 1: Pre-Deployment Verification
- [ ] Verify commit hash and branch (see Pre-Deployment Checklist)
- [ ] Check contract sizes
- [ ] Run test suite
- [ ] Verify RPC connectivity and deployer balance

### Step 2: Deploy Core Escrow (vNext)

**⚠️ IMPORTANT**: Skip ops contracts if reusing existing addresses.

```bash
# Set compiler runs to keep bytecode under 24KB
export SOLC_RUNS=200

# Deploy EscrowVault (vNext with security fixes)
pnpm hardhat deploy --network baseSepolia --tags escrow

# Optional: Deploy EscrowableERC20 if needed
# pnpm hardhat deploy --network baseSepolia --tags escrowable-erc20
```

**Expected Output:**
- New `EscrowVault` address (different from original IEO deployment)
- Contract size < 24KB
- Deployment transaction hash

**Record:**
- [ ] New `EscrowVault` address: `0x...`
- [ ] Deployment transaction hash: `0x...`
- [ ] Block number: `...`

### Step 3: Wire Escrow to Existing Infrastructure

- [ ] **Register escrow with ops contracts**:
  ```bash
  # This should happen automatically via deployment scripts
  # Verify: Check that EscrowVault is registered with CreateOps, SettlementOps, etc.
  ```

- [ ] **Set default modules** (if not set automatically):
  ```bash
  # Set default release strategy (if DefaultReleaseStrategy already deployed)
  # Use existing ModuleManagementContract address
  ```

- [ ] **Verify module swap wrappers exist**:
  ```bash
  pnpm hardhat console --network baseSepolia
  # const vault = await hre.ethers.getContractAt("EscrowVault", "NEW_VAULT_ADDRESS");
  # Check: vault.queueDefaultReleaseStrategy
  # Check: vault.activateDefaultReleaseStrategy
  ```

### Step 4: Governance Role Wiring (if needed)

- [ ] **Verify governance roles** (if reusing existing governance):
  ```bash
  # EscrowVault should have ROLE_ADMIN_CONTRACT on EscrowAdminContract
  # EscrowVault should have ROLE_ESCROW_CONTRACT on ModuleManagementContract
  ```

- [ ] **Run governance wiring** (if needed):
  ```bash
  pnpm hardhat deploy --network baseSepolia --tags governance
  ```

### Step 5: Post-Deployment Validation

#### Smoke Tests
- [ ] **Test createEscrow**:
  ```bash
  # Use smoke test script or manual test
  scripts/testnet/smoke-escrow.sh
  ```

- [ ] **Test module swap** (critical for vNext):
  ```bash
  # Queue default release strategy
  # Activate default release strategy
  # Verify new escrows use new default
  ```

- [ ] **Test Aave integration** (if AaveYieldGenerationModule deployed):
  ```bash
  # Verify Aave hooks are accessible
  # Test Aave module swapping (if deployed)
  # Verify size optimizations allow Aave within 24KB limit
  ```

- [ ] **Test security fixes**:
  - [ ] Verify `recipientCancel` and `senderCancel` have reentrancy guards
  - [ ] Verify zero-address checks in `setFeeRecipient` and `setResolutionModule`
  - [ ] Test fee-on-transfer token rejection (should revert with `AccountingDeficit`)

#### Version Report Generation
- [ ] **Generate version report**:
  ```bash
  pnpm hardhat run --network baseSepolia scripts/verify-base-sepolia.ts
  ```

- [ ] **Verify output**: Check `deployments/baseSepolia/reports/version-report.json` exists

#### Source Verification
- [ ] **Verify source code on Basescan**:
  ```bash
  pnpm hardhat run --network baseSepolia scripts/verify-base-sepolia-sources.ts
  ```

- [ ] **Record verification status**: Note which contracts verified successfully

---

## Post-Deployment Tasks

### Documentation Updates
- [ ] **Update `deployed.md`**:
  - Add new `EscrowVault` address
  - Mark original `EscrowVault` as "superseded by vNext"
  - Add deployment date and commit hash

- [ ] **Update `BASE_SEPOLIA_TESTNET_RELEASE_SUMMARY.md`**:
  - Mark vNext as "Deployed" (change from "Ready")
  - Add deployment date and addresses
  - Update "What's currently released" section

- [ ] **Create git tag**:
  ```bash
  git tag -a deployed-baseSepolia-2026-01-22-vnext -m "Base Sepolia IEO vNext deployment (includes Aave integration)"
  git push origin deployed-baseSepolia-2026-01-22-vnext
  ```

- [ ] **Merge testnet/validation tests** (post-deployment):
  ```bash
  # After deployment validation, merge testnet/validation branch tests
  # These tests were run against deployed contracts and provide additional coverage
  ```

### Partner Communication
- [ ] **Prepare address migration notice** (see `VNEXT_ADDRESS_MIGRATION.md`)
- [ ] **Notify partners** of new addresses
- [ ] **Provide cutover timeline** (if applicable)

### Artifact Export
- [ ] **Export deployment artifacts**:
  ```bash
  pnpm hardhat export --network baseSepolia
  ```

- [ ] **Backup artifacts**: Save `deployments/baseSepolia/` directory

---

## Rollback Procedure (if needed)

If deployment fails or issues are discovered:

1. **Stop using new addresses**: Do not proceed with partner cutover
2. **Document issues**: Record what went wrong
3. **Assess impact**: Determine if rollback is needed
4. **Notify partners**: Inform of delay/cancellation
5. **Revert to original**: Continue using original IEO addresses if safe

**Note**: Rollback is only possible if partners haven't cut over to new addresses yet.

---

## Verification Checklist

Before considering deployment complete:

- [ ] All smoke tests pass
- [ ] Module swap functionality verified
- [ ] Security fixes verified (reentrancy guards, zero-address checks)
- [ ] Version report generated successfully
- [ ] Source code verified on Basescan (or documented why not)
- [ ] Documentation updated
- [ ] Git tag created
- [ ] Partners notified (if applicable)

---

## Troubleshooting

### Contract Size Exceeds 24KB
- **Solution**: Ensure `SOLC_RUNS=200` is set before deployment
- **Check**: Run `forge build --sizes` to verify

### Deployment Fails with "replacement fee too low"
- **Solution**: Set fee overrides:
  ```bash
  export TX_MAX_FEE_GWEI=2
  export TX_PRIORITY_FEE_GWEI=1
  ```

### Module Swap Wrappers Missing
- **Solution**: Verify you're on commit `c2b140d` or later
- **Check**: Run `SwapWrapperSurface.t.sol` test to verify

### Ops Contracts Not Found
- **Solution**: If reusing existing ops, verify addresses in `deployed.md`
- **Action**: Update deployment scripts to use existing addresses

---

## Related Documents

- `BASE_SEPOLIA_CORE_TESTNET_GUIDE.md` - General deployment guide
- `BASE_SEPOLIA_TESTNET_RELEASE_SUMMARY.md` - Release status and known issues
- `VNEXT_ADDRESS_MIGRATION.md` - Partner migration guide
- `VNEXT_VS_ORIGINAL_COMPARISON.md` - Detailed change comparison

---

**Last Updated:** 2026-01-21  
**Note:** This release includes Aave integration from `next/aave` branch. All Aave tests passing, contracts approaching 24KB limit with optimizations.
