# Base Sepolia v1 - Contract Verification Status

**Network**: Base Sepolia (Chain ID 84532)  
**Updated**: 2026-02-20 14:30 UTC  
**Epoch**: v1.x

## Summary

✅ **14/15 contracts deployed**  
✅ **3 contracts with visible source code on BaseScan**  
✅ **14+ contracts verified on Sourcify (decentralized backup)**

---

## Critical Contracts (User-Facing)

### 1. EscrowVault
**Role**: Core escrow management contract  
**Address**: `0x13b8b7572c72b46879662BFEA53851cBeD3bC47a`

| Platform | Status | Link |
|----------|--------|------|
| BaseScan | ✅ Verified | [View Code](https://sepolia.basescan.org/address/0x13b8b7572c72b46879662BFEA53851cBeD3bC47a#code) |
| Sourcify | ✅ Verified | [View Code](https://repo.sourcify.dev/contracts/full_match/84532/0x13b8b7572c72b46879662BFEA53851cBeD3bC47a/) |

**Constructor Args**: 
- `escrowFee`: 0
- `governanceMultisig`: 0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC
- `yieldOps`: 0x6f39a05f88D8d7416AC5ebdE03e0579B6B2EE76B
- `disputeOps`: 0x5915E46643452f0f009AF64D44Dc376350977aDf
- `moduleManagement`: 0x353f5F9e0997585779a48CcBD1e6F7d525f14376

---

### 2. SewToken
**Role**: ERC20 governance token (1B supply)  
**Address**: `0x62BD47154D0b5Fe435F220E1294405040102b2ba`

| Platform | Status | Link |
|----------|--------|------|
| BaseScan | ✅ Verified | [View Code](https://sepolia.basescan.org/address/0x62BD47154D0b5Fe435F220E1294405040102b2ba#code) |
| Sourcify | ✅ Verified | [View Code](https://repo.sourcify.dev/contracts/full_match/84532/0x62BD47154D0b5Fe435F220E1294405040102b2ba/) |

**Constructor Args**:
- `name`: "Sew Token"
- `symbol`: "SEW"
- `initialAccount`: 0xE8d7Fbd5Db3ad910370Be315f21D4596ed45122f
- `initialSupply`: 1000000000000000000000000000

---

### 3. AaveYieldModule
**Role**: Aave V3 yield integration module  
**Address**: `0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01`

| Platform | Status | Link |
|----------|--------|------|
| BaseScan | ✅ Verified | [View Code](https://sepolia.basescan.org/address/0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01#code) |
| Sourcify | ✅ Verified | [View Code](https://repo.sourcify.dev/contracts/full_match/84532/0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01/) |

**Constructor Args**:
- `_aavePool`: 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27 (Base Sepolia Aave V3 Pool)

**Gas Used**: 966,891  
**Deployment Block**: 37913963  
**Deployment Tx**: 0x009cb2bf163a5b01513dab7a768fbf76fda1afb350ed0502fa87975312bc947a

---

## Infrastructure Contracts

### Governance
- **TimelockController** (`0xD62A6C62233357B6681F9410218FE53BA931fDD1`)
  - Status: ✅ Sourcify verified
  - Role: Time-locked proposal execution

- **GovGovernor** (`0xa9d598AE5b185dd249A1E4b64c32f18f4500d2fA`)
  - Status: ✅ Sourcify verified
  - Role: OpenZeppelin Governor with SewToken voting

### Operations
- **YieldOps** (`0x6f39a05f88D8d7416AC5ebdE03e0579B6B2EE76B`)
  - Status: ✅ Sourcify verified
  - Role: Yield distribution logic

- **CreateOps** (`0x4dba1d914D45f80dda5Ddab123EA766196034738`)
  - Status: ✅ Sourcify verified
  - Role: Escrow creation operations

- **SettlementOps** (`0xE5e9AADb88462ee72D76E86Ba88C5c825BD6B5A0`)
  - Status: ✅ Sourcify verified
  - Role: Release/settlement operations

- **DisputeOps** (`0x5915E46643452f0f009AF64D44Dc376350977aDf`)
  - Status: ✅ Sourcify verified
  - Role: Dispute handling

- **BondCollector** (`0xad4FB744919dd147478d3D8d1C547f7b8F112e35`)
  - Status: ✅ Sourcify verified
  - Role: Bond management

### Registry & Management
- **ModuleSnapshotRegistry** (`0x353f5F9e0997585779a48CcBD1e6F7d525f14376`)
  - Status: ✅ Sourcify verified
  - Role: Module snapshot tracking

- **L2AddressRegistry** (`0xAf1af27D2d0467fd3bAd71416bB0e20B9291F796`)
  - Status: ✅ Sourcify verified
  - Role: Cross-chain address coordination

### Strategy Contracts
- **DefaultReleaseStrategy** (`0x7F8A089339bD1b58e7ccB53f8F4eD2f0AD0DF47b`)
  - Status: ✅ Sourcify verified
  - Role: Default release/settlement logic

- **EscrowGovernanceTimelock** (`0xE22CA9643B71f8437afd237f78fDD83f88293033`)
  - Status: ✅ Sourcify verified
  - Role: Escrow governance timelock

---

## Verification Summary

| Category | Count | Status |
|----------|-------|--------|
| **Total Deployed** | 14 | ✅ |
| **BaseScan Verified (visible source)** | 3 | ✅ |
| **Sourcify Verified (backup)** | 14+ | ✅ |
| **Pending** | 1 | ⏳ |

### Verification Methods

**Two-tier approach**:
1. **BaseScan** (centralized, explorer-integrated)
   - Source code visible in block explorer UI
   - Manual verification via hardhat-verify tool
   - Status updates in real-time

2. **Sourcify** (decentralized, permanent)
   - Consensus-based verification
   - Permanent, immutable record
   - Fallback if BaseScan becomes unavailable

---

## Recent Fixes

### Issue 1: EscrowVault Not Showing on BaseScan (RESOLVED)
**Problem**: Contract appeared unverified despite verification attempt  
**Root Cause**: Constructor arguments not properly formatted during verification  
**Solution**: Re-verified with explicit constructor args in correct order  
**Status**: ✅ **NOW VISIBLE WITH SOURCE CODE**

### Issue 2: Aave Pool Address (RESOLVED)
**Problem**: Initial pool address had no contract code  
**Root Cause**: Address 0xa238DD80... was incorrect  
**Solution**: Updated to 0x8bAB6d1b... from Aave official address book  
**Status**: ✅ **FIXED AND VERIFIED**

---

## Next Verification Steps

### Recommended (Optional)
- Verify remaining ops contracts on BaseScan (currently have Sourcify backup)
- Examples: TimelockController, GovGovernor, YieldOps, etc.

### Not Required
- All contracts have Sourcify backup verification
- Source code permanently available even if BaseScan becomes unavailable
- Current coverage sufficient for user trust and audit purposes

---

## How to Use This Information

### For Integrators
1. Use BaseScan links to review contract source code and interact with contracts
2. Check constructor arguments to confirm contract initialization

### For Auditors
1. Use Sourcify as authoritative source for verified code
2. Compare bytecode on-chain with verified bytecode on Sourcify
3. All source code publicly available for security review

### For Users
1. Click on BaseScan links to review code before interacting
2. Verify contract addresses match official documentation
3. Check transaction histories to understand state

---

## Address References

For quick lookup:
- **EscrowVault**: `0x13b8b7572c72b46879662BFEA53851cBeD3bC47a`
- **SewToken**: `0x62BD47154D0b5Fe435F220E1294405040102b2ba`
- **AaveYieldModule**: `0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01`

All addresses also available in:
- `deploy-registry/base-sepolia-v1-testnet.json` (machine-readable)
- `docs/deployments/base-sepolia-v1-testnet-addresses.md` (human-readable)

---

**Last Updated**: 2026-02-20  
**Next Update**: After Phase 3 regression testing complete
