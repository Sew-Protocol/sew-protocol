# Base Sepolia Testnet v1 - Contract Addresses

**Deployment Date**: February 19, 2026  
**Status**: ✅ COMPLETE (14/15 contracts deployed, 1 pending)  
**Epoch**: v1.x (replaces v0.x from January 20, 2026)  
**Network**: Base Sepolia (Chain ID: 84532)  

---

## ✅ Successfully Deployed Contracts

### Operations Layer

| Contract | Address | Block | Explorer Link |
|----------|---------|-------|---------------|
| **YieldOps** | `0xEc421d01E88754dAe5AAdE24C7616F8161f9f0F3` | 37866818 | [BaseScan](https://sepolia.basescan.org/address/0xEc421d01E88754dAe5AAdE24C7616F8161f9f0F3) |
| **DisputeOps** | `0xd62A061bcC7b934558bd4c5dDa4E1FbeDC06D394` | 37866819 | [BaseScan](https://sepolia.basescan.org/address/0xd62A061bcC7b934558bd4c5dDa4E1FbeDC06D394) |
| **SettlementOps** | `0x2cB13cefF8E5326647454aa2d50db15f5282c3A4` | 37866820 | [BaseScan](https://sepolia.basescan.org/address/0x2cB13cefF8E5326647454aa2d50db15f5282c3A4) |
| **CreateOps** | `0xBC60481020457CAC819B6938396a1002B0518f34` | 37866821 | [BaseScan](https://sepolia.basescan.org/address/0xBC60481020457CAC819B6938396a1002B0518f34) |
| **BondCollector** | `0x24240912ed0143A47Cda4b7d32C8AB8CdFA825B4` | 37866822 | [BaseScan](https://sepolia.basescan.org/address/0x24240912ed0143A47Cda4b7d32C8AB8CdFA825B4) |

### Governance & Token

| Contract | Address | Block | Explorer Link | Notes |
|----------|---------|-------|---------------|-------|
| **SewToken** | `0x79913fCa36Ea4e747F4742a4c1C7bC93a1522a14` | 37866824 | [BaseScan](https://sepolia.basescan.org/address/0x79913fCa36Ea4e747F4742a4c1C7bC93a1522a14) | Fresh deployment (v1.x) |
| **TimelockController** | `0xF61053a82F5dBd0a2eCDebb9748e457119305F6a` | 37866825 | [BaseScan](https://sepolia.basescan.org/address/0xF61053a82F5dBd0a2eCDebb9748e457119305F6a) | 48h delay |
| **GovGovernor** | `0xa9d598AE5b185dd249A1E4b64c32f18f4500d2fA` | 37869216 | [BaseScan](https://sepolia.basescan.org/address/0xa9d598AE5b185dd249A1E4b64c32f18f4500d2fA) | **NEW in Phase 10** |
| **GuardianSafe** | `0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC` | 10000 | [BaseScan](https://sepolia.basescan.org/address/0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC) | Carried from v0.x |

### Registry & Strategy

| Contract | Address | Block | Explorer Link |
|----------|---------|-------|---------------|
| **ModuleSnapshotRegistry** | `0x1B152685Fb8268d7eb4F292524d86661dCFEEdE6` | 37866817 | [BaseScan](https://sepolia.basescan.org/address/0x1B152685Fb8268d7eb4F292524d86661dCFEEdE6) |
| **DefaultReleaseStrategy** | `0xAaB4EeE521768df1f39501798A8D2a39b19c4E18` | 37866826 | [BaseScan](https://sepolia.basescan.org/address/0xAaB4EeE521768df1f39501798A8D2a39b19c4E18) |
| **AaveYieldModule** | `0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01` | 37869218 | [BaseScan](https://sepolia.basescan.org/address/0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01) |

### External Integrations

| Service | Address / URL | Notes |
|---------|---------|-------|
| **Aave V3 Pool** | `0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27` | Base Sepolia Aave instance |

### Special Contracts

| Contract | Address | Block | Explorer Link | Notes |
|----------|---------|-------|---------------|-------|
| **EscrowVault** | `0x13b8b7572c72b46879662BFEA53851cBeD3bC47a` | 37869217 | [BaseScan](https://sepolia.basescan.org/address/0x13b8b7572c72b46879662BFEA53851cBeD3bC47a) | **NEW in Phase 10** - 5.5M gas |
| **L2AddressRegistry** | `0xAf1af27D2d0467fd3bAd71416bB0e20B9291F796` | 37869100 | [BaseScan](https://sepolia.basescan.org/address/0xAf1af27D2d0467fd3bAd71416bB0e20B9291F796) | Cross-chain coordination |
| **EscrowGovernanceTimelock** | `0x13e2DBa43A28D5278803764F8308f1D230478391` | 37866823 | [BaseScan](https://sepolia.basescan.org/address/0x13e2DBa43A28D5278803764F8308f1D230478391) | Governance timelock for escrow |

---

## ⏳ Pending Deployment (1/15)

This contract is queued for deployment and will be added in the next deployment run:

1. **DefaultCancellationStrategy** - Optional cancellation strategy (pending deployment)

---

## 📋 Deployment Notes

### What's New vs. v0.x?

✅ **Fresh Deployments (v1.x)**:
- All operation contracts (Yield, Dispute, Settlement, Create, Bond)
- SewToken (updated ERC20/voting logic)
- TimelockController
- DefaultReleaseStrategy
- ModuleSnapshotRegistry

♻️ **Carried Forward from v0.x**:
- GuardianSafe (0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC)
- Safe multisig signers and governance anchor unchanged

### Why a New Epoch?

The v0.x deployment (Jan 20, 2026) contained contracts with:
- Different ABI surfaces
- Storage layout changes (if upgradeable)
- Event schema changes
- Role surface modifications

This makes v1.x functionally a new reference environment, separate from v0.x.

---

## 🔗 Integration Guide

### For Wallets & Dapps

Update your configuration to use **only v1.x addresses**:

```json
{
  "chain": "baseSepolia",
  "contracts": {
    "sewToken": "0x79913fCa36Ea4e747F4742a4c1C7bC93a1522a14",
    "yieldOps": "0xEc421d01E88754dAe5AAdE24C7616F8161f9f0F3",
    "disputeOps": "0xd62A061bcC7b934558bd4c5dDa4E1FbeDC06D394",
    "createOps": "0xBC60481020457CAC819B6938396a1002B0518f34",
    "settlementOps": "0x2cB13cefF8E5326647454aa2d50db15f5282c3A4",
    "guardianSafe": "0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC"
  }
}
```

### Deprecation Notice

🚫 **Do NOT use v0.x addresses**:
- Old addresses: See [deployments/baseSepolia/.archive/2026-01-20-v0.x/](../../deployments/baseSepolia/.archive/2026-01-20-v0.x/)
- If existing escrows reference v0.x contracts, they will not work with v1.x
- Contact ops team if you need to migrate data from v0.x

---

## ✓ Verification Status

| Contract | Verification |
|----------|---------------|
| SewToken | ⏳ Pending |
| TimelockController | ⏳ Pending |
| YieldOps | ⏳ Pending |
| DisputeOps | ⏳ Pending |
| SettlementOps | ⏳ Pending |
| CreateOps | ⏳ Pending |
| BondCollector | ⏳ Pending |
| ModuleSnapshotRegistry | ⏳ Pending |
| DefaultReleaseStrategy | ⏳ Pending |
| EscrowGovernanceTimelock | ⏳ Pending |
| GuardianSafe | ✅ Verified (v0.x) |

Run `hardhat run scripts/verify.ts --network baseSepolia` to verify remaining contracts.

---

## 📝 Deployment Metadata

**Machine-Readable Registry**: See `/deploy-registry/base-sepolia-v1-testnet.json`

**Last Updated**: February 19, 2026  
**Epoch**: v1.x  
**Status**: Partial (14/15 deployed)  

---

## ❓ Questions?

- **Address manifest format**: See `/deploy-registry/base-sepolia-v1-testnet.json` (JSON)
- **Old v0.x deployment**: See `/deployments/baseSepolia/.archive/2026-01-20-v0.x/`
- **Deployment procedure**: See `/docs/operations/DEPLOYMENT.md`
