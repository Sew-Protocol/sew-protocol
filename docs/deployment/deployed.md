## Base Sepolia deployed contracts

- **chainId**: 84532
- **Explorer**: `https://sepolia.basescan.org`

### Governance infrastructure

| Contract | Description | Address | Explorer |
|---|---|---|---|
| `SewToken` | Governance token used for voting | `0x7428c13e158ab6eB3E9e7780f05d58181172Ab5A` | `https://sepolia.basescan.org/address/0x7428c13e158ab6eB3E9e7780f05d58181172Ab5A` |
| `TimelockController` | Governance timelock (executes queued proposals) | `0xF0f2134CB24296781ABCa41A536c7C17600a7E47` | `https://sepolia.basescan.org/address/0xF0f2134CB24296781ABCa41A536c7C17600a7E47` |
| `GovGovernor` | On-chain Governor (absolute quorum) | `0xaFf6b4b8cF3bBDa62d4A40839c6c8244aacAC166` | `https://sepolia.basescan.org/address/0xaFf6b4b8cF3bBDa62d4A40839c6c8244aacAC166` |

### Testnet safes / operators

| Contract | Description | Address | Explorer |
|---|---|---|---|
| `Safe_Multisig (EOA)` | Safe multisig (testnet; may be same as guardian) | `0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC` | `https://sepolia.basescan.org/address/0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC` |
| `GuardianSafe (EOA)` | Guardian multisig (testnet; may be same as governance safe) | `0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC` | `https://sepolia.basescan.org/address/0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC` |

### Ops contracts

| Contract | Description | Address | Explorer |
|---|---|---|---|
| `CreateOps` | Create ops router (escrow creation orchestration) | `0x7816EB2022B7AFB3A53a41eaa5ED5a2c3924De3b` | `https://sepolia.basescan.org/address/0x7816EB2022B7AFB3A53a41eaa5ED5a2c3924De3b` |
| `SettlementOps` | Settlement ops router (release/cancel/settlement orchestration) | `0x1d0BE2d3b91A26537b5A8d75Ae721dE5Ea1a4054` | `https://sepolia.basescan.org/address/0x1d0BE2d3b91A26537b5A8d75Ae721dE5Ea1a4054` |
| `DisputeOps` | Dispute ops router (dispute flow orchestration) | `0x5456edb1f266D6F3FaeAfFa4be33a7891eC9b3D2` | `https://sepolia.basescan.org/address/0x5456edb1f266D6F3FaeAfFa4be33a7891eC9b3D2` |
| `YieldOps` | Yield ops router (yield deposit/withdraw orchestration) | `0xFf1AaC122A1Ab02aA76E43Cf8641A4a33277C653` | `https://sepolia.basescan.org/address/0xFf1AaC122A1Ab02aA76E43Cf8641A4a33277C653` |
| `BondCollector` | Bond/fee collector helper (as configured) | `0x0f0526297983260fa92e71149322f13d74B4Cdca` | `https://sepolia.basescan.org/address/0x0f0526297983260fa92e71149322f13d74B4Cdca` |

### Core escrow

| Contract | Description | Address | Explorer |
|---|---|---|---|
| `EscrowVault` | Core escrow contract (multi-token) | `0xBcDefBdEEA5C00f128bE83534646427b7248c5F9` | `https://sepolia.basescan.org/address/0xBcDefBdEEA5C00f128bE83534646427b7248c5F9` |

### Admin & module management

| Contract | Description | Address | Explorer |
|---|---|---|---|
| `EscrowAdminContract` | Slow-lane admin helper (holds minimal admin role) | `0x34fF47Ee2f95C35ec1e012DdD2D7394D7C644931` | `https://sepolia.basescan.org/address/0x34fF47Ee2f95C35ec1e012DdD2D7394D7C644931` |
| `ModuleManagementContract` | Slow-lane module default management | `0xaa0Fa9C11af77E7f2BF14f86C17C8436370F0a86` | `https://sepolia.basescan.org/address/0xaa0Fa9C11af77E7f2BF14f86C17C8436370F0a86` |