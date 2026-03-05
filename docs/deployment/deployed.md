## Base Sepolia deployed contracts

- **chainId**: 84532
- **Explorer**: `https://sepolia.basescan.org`
- **Deployment Date**: 2026-02-19 (v1.x epoch)
- **Status**: All 14/15 core contracts deployed and operational

### Governance infrastructure

| Contract | Description | Address |
|---|---|---|
| `SewToken` | Governance token used for voting | [`0x79913fCa36Ea4e747F4742a4c1C7bC93a1522a14`](https://sepolia.basescan.org/address/0x79913fCa36Ea4e747F4742a4c1C7bC93a1522a14) |
| `TimelockController` | Governance timelock (executes queued proposals) | [`0xF61053a82F5dBd0a2eCDebb9748e457119305F6a`](https://sepolia.basescan.org/address/0xF61053a82F5dBd0a2eCDebb9748e457119305F6a) |
| `GovGovernor` | On-chain Governor (absolute quorum) | [`0xa9d598AE5b185dd249A1E4b64c32f18f4500d2fA`](https://sepolia.basescan.org/address/0xa9d598AE5b185dd249A1E4b64c32f18f4500d2fA) |

### Testnet safes / operators

| Contract | Description | Address |
|---|---|---|
| `GuardianSafe` | Guardian multisig (carried forward from v0.x) | [`0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC`](https://sepolia.basescan.org/address/0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC) |

### Ops contracts

| Contract | Description | Address |
|---|---|---|
| `CreateOps` | Create ops router (escrow creation orchestration) | [`0xBC60481020457CAC819B6938396a1002B0518f34`](https://sepolia.basescan.org/address/0xBC60481020457CAC819B6938396a1002B0518f34) |
| `SettlementOps` | Settlement ops router (release/cancel/settlement orchestration) | [`0x2cB13cefF8E5326647454aa2d50db15f5282c3A4`](https://sepolia.basescan.org/address/0x2cB13cefF8E5326647454aa2d50db15f5282c3A4) |
| `DisputeOps` | Dispute ops router (dispute flow orchestration) | [`0xd62A061bcC7b934558bd4c5dDa4E1FbeDC06D394`](https://sepolia.basescan.org/address/0xd62A061bcC7b934558bd4c5dDa4E1FbeDC06D394) |
| `YieldOps` | Yield ops router (yield deposit/withdraw orchestration) | [`0xEc421d01E88754dAe5AAdE24C7616F8161f9f0F3`](https://sepolia.basescan.org/address/0xEc421d01E88754dAe5AAdE24C7616F8161f9f0F3) |
| `BondCollector` | Bond/fee collector helper (as configured) | [`0x24240912ed0143A47Cda4b7d32C8AB8CdFA825B4`](https://sepolia.basescan.org/address/0x24240912ed0143A47Cda4b7d32C8AB8CdFA825B4) |

### Core escrow

| Contract | Description | Address |
|---|---|---|
| `EscrowVault` | Core escrow contract (multi-token) | [`0x13b8b7572c72b46879662BFEA53851cBeD3bC47a`](https://sepolia.basescan.org/address/0x13b8b7572c72b46879662BFEA53851cBeD3bC47a) |

### Module management

| Contract | Description | Address |
|---|---|---|
| `ModuleSnapshotRegistry` | Module registry for snapshot and metadata | [`0x1B152685Fb8268d7eb4F292524d86661dCFEEdE6`](https://sepolia.basescan.org/address/0x1B152685Fb8268d7eb4F292524d86661dCFEEdE6) |
| `ModuleRegistry` | Module registry for snapshot and metadata | [`0x353f5F9e0997585779a48CcBD1e6F7d525f14376`](https://sepolia.basescan.org/address/0x353f5F9e0997585779a48CcBD1e6F7d525f14376) |
| `L2AddressRegistry` | L2 address registry for cross-chain coordination | [`0xAf1af27D2d0467fd3bAd71416bB0e20B9291F796`](https://sepolia.basescan.org/address/0xAf1af27D2d0467fd3bAd71416bB0e20B9291F796) |

### Yield modules

| Contract | Description | Address | Status |
|---|---|---|---|
| `DefaultReleaseStrategy` | Default release strategy module | [`0xAaB4EeE521768df1f39501798A8D2a39b19c4E18`](https://sepolia.basescan.org/address/0xAaB4EeE521768df1f39501798A8D2a39b19c4E18) | Deployed |
| `AaveYieldModule` | Aave V3 yield module | [`0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01`](https://sepolia.basescan.org/address/0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01) | ✅ Verified on BaseScan & Sourcify |

### Governance infrastructure (additional)

| Contract | Description | Address |
|---|---|---|
| `EscrowGovernanceTimelock` | Governance timelock for escrow | [`0x13e2DBa43A28D5278803764F8308f1D230478391`](https://sepolia.basescan.org/address/0x13e2DBa43A28D5278803764F8308f1D230478391) |