# IEO vNext Address Migration Guide

**For:** Partners, Exchanges, and Integration Teams  
**Release:** IEO vNext (Base Sepolia Testnet)  
**Date:** 2026-01-21  
**Network:** Base Sepolia (chainId 84532)

---

## Executive Summary

IEO vNext includes security hardening and module swap restoration. **Some contract addresses will change**, while others remain the same. This guide helps you migrate from the original IEO deployment to vNext.

**Key Points:**
- ✅ **Core escrow contracts** (`EscrowVault`, `EscrowableERC20`) will have **new addresses**
- ✅ **Ops contracts** (`CreateOps`, `SettlementOps`, etc.) **remain the same** (reused)
- ✅ **Governance infrastructure** (`GovGovernor`, `TimelockController`, `SewToken`) **remains the same**
- ✅ **No breaking API changes**: Contract interfaces are backward compatible

---

## Address Changes

### Contracts with NEW Addresses (vNext)

| Contract | Original IEO Address | vNext Address | Status |
|----------|---------------------|---------------|--------|
| `EscrowVault` | `0xBcDefBdEEA5C00f128bE83534646427b7248c5F9` | `TBD` (will be provided after deployment) | ⚠️ **MUST UPDATE** |
| `EscrowableERC20` | Not deployed | `TBD` (if deployed) | ⚠️ **UPDATE IF USED** |

**Action Required:**
- Update your integration to use the new `EscrowVault` address
- If you use `EscrowableERC20`, update to new address (if deployed)

### Contracts with SAME Addresses (Reused)

| Contract | Address | Status |
|----------|---------|--------|
| `CreateOps` | `0x7816EB2022B7AFB3A53a41eaa5ED5a2c3924De3b` | ✅ **NO CHANGE** |
| `SettlementOps` | `0x1d0BE2d3b91A26537b5A8d75Ae721dE5Ea1a4054` | ✅ **NO CHANGE** |
| `DisputeOps` | `0x5456edb1f266D6F3FaeAfFa4be33a7891eC9b3D2` | ✅ **NO CHANGE** |
| `YieldOps` | `0xFf1AaC122A1Ab02aA76E43Cf8641A4a33277C653` | ✅ **NO CHANGE** |
| `BondCollector` | `0x0f0526297983260fa92e71149322f13d74B4Cdca` | ✅ **NO CHANGE** |
| `EscrowAdminContract` | `0x34fF47Ee2f95C35ec1e012DdD2D7394D7C644931` | ✅ **NO CHANGE** |
| `ModuleManagementContract` | `0xaa0Fa9C11af77E7f2BF14f86C17C8436370F0a86` | ✅ **NO CHANGE** |
| `DefaultReleaseStrategy` | `0x9738584Db6D171e6BE9d0F104aAbF4C1cAd0fb3b` | ✅ **NO CHANGE** |
| `SewToken` | `0x7428c13e158ab6eB3E9e7780f05d58181172Ab5A` | ✅ **NO CHANGE** |
| `TimelockController` | `0xF0f2134CB24296781ABCa41A536c7C17600a7E47` | ✅ **NO CHANGE** |
| `GovGovernor` | `0xaFf6b4b8cF3bBDa62d4A40839c6c8244aacAC166` | ✅ **NO CHANGE** |

**Action Required:**
- ✅ **No action needed** for these contracts
- Continue using existing addresses

---

## Migration Steps

### Step 1: Receive New Addresses

After vNext deployment, you will receive:
- New `EscrowVault` address
- New `EscrowableERC20` address (if deployed)
- Deployment transaction hash
- Block number
- Basescan verification links

**Source of Truth:**
- `docs/deployment/deployed.md` (human-readable index)
- `deployments/baseSepolia/reports/version-report.json` (machine-readable)

### Step 2: Update Your Configuration

#### Configuration Files
Update your environment variables, config files, or database:

```bash
# Before (Original IEO)
ESCROW_VAULT_ADDRESS=0xBcDefBdEEA5C00f128bE83534646427b7248c5F9

# After (vNext)
ESCROW_VAULT_ADDRESS=<NEW_ADDRESS_FROM_DEPLOYMENT>
```

#### Code Updates
If you hardcode addresses in your code:

```solidity
// Before
IEscrowVault constant VAULT = IEscrowVault(0xBcDefBdEEA5C00f128bE83534646427b7248c5F9);

// After
IEscrowVault constant VAULT = IEscrowVault(<NEW_ADDRESS>);
```

### Step 3: Verify New Contracts

Before switching over, verify the new contracts:

1. **Check Basescan**: Verify source code is verified
   - URL: `https://sepolia.basescan.org/address/<NEW_ADDRESS>`

2. **Verify contract code**: Ensure bytecode matches expected
   ```bash
   # Use version report script
   pnpm hardhat run --network baseSepolia scripts/verify-base-sepolia.ts
   ```

3. **Test connectivity**: Ensure you can interact with new contract
   ```bash
   pnpm hardhat console --network baseSepolia
   # const vault = await hre.ethers.getContractAt("EscrowVault", "<NEW_ADDRESS>");
   # await vault.escrowFee(); // Should return current fee
   ```

### Step 4: Test Integration

Before full cutover, test your integration:

- [ ] **Create escrow**: Test `createEscrow` with new address
- [ ] **Release escrow**: Test `releaseEscrowTransfer`
- [ ] **Cancel escrow**: Test `recipientCancel` and `senderCancel`
- [ ] **Event indexing**: Verify events are emitted correctly
- [ ] **Module swap** (if applicable): Test `queueDefaultReleaseStrategy` / `activateDefaultReleaseStrategy`

### Step 5: Cutover

**Recommended Approach: Gradual Cutover**

1. **Dual-write period** (optional):
   - Write to both old and new addresses for a short period
   - Monitor new address for issues
   - Gradually shift traffic to new address

2. **Full cutover**:
   - Update all references to new address
   - Stop using old address
   - Monitor for issues

**Timeline:**
- **Recommended**: Allow 24-48 hours for testing before full cutover
- **Minimum**: Test new address thoroughly before switching

---

## What Changed in vNext

### Security Improvements (No API Changes)
- ✅ Reentrancy guards added to `recipientCancel` and `senderCancel`
- ✅ Zero-address validation in `setFeeRecipient` and `setResolutionModule`
- ✅ Accounting deficit protection (reverts on fee-on-transfer tokens)
- ✅ Improved fault code telemetry (`CONTRACT_INSUFFICIENT_BALANCE`)

### New Functionality (Backward Compatible)
- ✅ Module swap wrappers restored (`queueDefaultReleaseStrategy`, `activateDefaultReleaseStrategy`)
- ✅ Proposal threshold updated to 50k tokens (from 100k)

### API Compatibility
- ✅ **All existing function signatures unchanged**
- ✅ **Event signatures unchanged**
- ✅ **Return types unchanged**
- ✅ **No breaking changes**

**Impact:** Your existing integration code should work without modification (only address change needed).

---

## Rollback Plan

If issues are discovered after cutover:

1. **Immediate**: Revert to original `EscrowVault` address (`0xBcDefBdEEA5C00f128bE83534646427b7248c5F9`)
2. **Document**: Report issues to deployment team
3. **Assess**: Determine if rollback is permanent or temporary

**Note**: Original IEO contracts remain deployed and functional. Rollback is possible if needed.

---

## Support & Questions

### Documentation
- **Deployment guide**: `docs/deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md`
- **Release summary**: `docs/deployment/BASE_SEPOLIA_TESTNET_RELEASE_SUMMARY.md`
- **Change comparison**: `docs/deployment/ieo/VNEXT_VS_ORIGINAL_COMPARISON.md`

### Verification
- **Basescan**: `https://sepolia.basescan.org`
- **Version report**: `deployments/baseSepolia/reports/version-report.json`
- **Git tag**: `deployed-baseSepolia-2026-01-21-vnext`

### Contact
- For deployment questions, refer to deployment team
- For integration issues, check documentation or open issue

---

## Checklist for Partners

Before cutover:
- [ ] Received new `EscrowVault` address
- [ ] Verified source code on Basescan
- [ ] Updated configuration files
- [ ] Tested integration with new address
- [ ] Verified events are indexed correctly
- [ ] Confirmed no API changes affect your code
- [ ] Planned cutover timeline

After cutover:
- [ ] All references updated to new address
- [ ] Monitoring new address for issues
- [ ] Old address no longer in use
- [ ] Integration tests passing
- [ ] Documented any issues encountered

---

## Timeline Example

**Day 1 (Deployment Day)**
- vNext contracts deployed
- New addresses provided
- Partners notified

**Day 2-3 (Testing Period)**
- Partners test new addresses
- Integration verification
- Issue resolution (if any)

**Day 4 (Cutover)**
- Partners switch to new addresses
- Monitor for issues
- Full cutover complete

**Day 5+ (Post-Cutover)**
- Monitor stability
- Address any issues
- Document learnings

---

**Last Updated:** 2026-01-21  
**Status:** vNext deployment scheduled for 2026-01-22 (addresses TBD)  
**Note:** This release includes Aave integration. Aave modules can be deployed and swapped in post-deployment.
