## Base Sepolia Core (IEO) Testnet Deployment Guide

### Scope
- **Goal**: deploy *core escrow contracts + ops contracts + admin helpers* on Base Sepolia for IEO-style integration testing (wallet + exchange flows).
- **Non-goal**: treat this as a public launch or final production deployment.

### Critical security note (do this first)
- **If a private key has ever been pasted into chat/issues/docs, assume it is compromised.**
- **Rotate immediately**:
  - **EOA key**: move any funds, stop using it, generate a new key.
  - **API keys** (Basescan/Etherscan/Alchemy): rotate if you don’t want them broadly visible.
- **Never commit** `.env` / keys / partner endpoints. Keep testnet deploy keys separate from governance deploy keys.

### Recommended key strategy (testnet)
- **`PRIVATE_KEY`**: keep as the “governance infra deployer” key if you already used it for `SewToken`, `TimelockController`, `GovGovernor`.
- **`SEPOLIA_DEPLOY_KEY`**: use as the “core escrow deployer” key for ops/core/module wiring.
  - This repo now supports `SEPOLIA_DEPLOY_KEY` specifically for `baseSepolia` in `hardhat.config.ts`.

### Environment variables (Base Sepolia)
Minimum for core deploy (examples; don’t paste real keys in public places):

```bash
RPC_BASE_SEPOLIA=https://sepolia.base.org
DEPLOY_CONFIRM=NO

# Core deploy key (Base Sepolia only)
SEPOLIA_DEPLOY_KEY=0x...

# Governance config (already deployed on your testnet, but needed for role wiring scripts)
SAFE_OWNER_1=0x...
SAFE_OWNER_2=0x...
SAFE_OWNER_3=0x...
SAFE_THRESHOLD=1
GUARDIAN_MULTISIG=0x...
FEE_RECIPIENT=0x...

# Governor config (absolute quorum for launch/testnet)
ABSOLUTE_QUORUM=4000000000000000000000000
PROPOSAL_THRESHOLD=10000000000000000000000000
TIMELOCK_DELAY=172800
VOTING_DELAY=1
VOTING_PERIOD=45818
```

### Deployment flow (core IEO testnet)
Assuming governance infra is already deployed and you now want core + ops under `SEPOLIA_DEPLOY_KEY`:

1) **Sanity check signer**

```bash
pnpm hardhat console --network baseSepolia
# In the console:
# const { getNamedAccounts, ethers } = hre;
# const { deployer } = await getNamedAccounts();
# deployer
# // or:
# (await ethers.getSigners())[0].address
```

2) **Deploy ops + module management + escrow admin helper**

```bash
pnpm hardhat deploy --network baseSepolia --tags yield-ops,dispute-ops,settlement-ops,create-ops,bond-collector,module-management,escrow-admin
```

**If you hit** `replacement fee too low` / `REPLACEMENT_UNDERPRICED`:
- You likely have a pending tx with the same nonce in the mempool.
- Either wait for it to confirm, or set fee overrides for the deploy run:

```bash
# Example values (tweak as needed)
export TX_MAX_FEE_GWEI=2
export TX_PRIORITY_FEE_GWEI=1
pnpm hardhat deploy --network baseSepolia --tags yield-ops,dispute-ops,settlement-ops,create-ops,bond-collector,module-management,escrow-admin
```

3) **Deploy core escrow**

```bash
export SOLC_RUNS=200  # keep bytecode under 24KB (EIP-170)
pnpm hardhat deploy --network baseSepolia --tags escrow
```

4) **Deploy default resolution + release strategy + (optional) yield modules**

```bash
pnpm hardhat deploy --network baseSepolia --tags default-resolution
# Deploy default release strategy module (`contracts/modules/DefaultReleaseStrategy.sol`)
pnpm hardhat deploy --network baseSepolia --tags release-strategy
# Optional yield modules if you want to test yield flows
pnpm hardhat deploy --network baseSepolia --tags yield-modules
```

5) **Governance/role wiring**
- If governance infra already exists, run the governance wiring step(s) as needed:

```bash
pnpm hardhat deploy --network baseSepolia --tags governance
```

### Operational precautions / markings
- **Naming**: label this deployment internally as **“Base Sepolia IEO – Integration Test Deployment”**.
- **Artifacts**:
  - export deployments after each step: `pnpm hardhat export --network baseSepolia`
  - record addresses + tx hashes in a shared (private) sheet/doc for the exchange partner.
- **Safety defaults (recommended for testnet)**
  - start with **yield deposits paused** (via `CreateOps.pauseYieldDeposits("testnet")`) unless yield is required for integration.
  - keep **guardian / fee recipient / safe** as a single address only for testing; do not mirror this to production.

### Test regime (practical checklist)
#### A) Smoke tests (same day)
- **createEscrow**:
  - basic create with minimal settings
  - create with custom settings (auto times on/off)
- **release / cancel**:
  - release by sender
  - cancel by sender/recipient (where allowed)
- **default module swapping (vNext required)**:
  - queue + activate `DefaultReleaseStrategy` via `EscrowVault.queueDefaultReleaseStrategy(...)` / `activateDefaultReleaseStrategy()`
  - confirm new defaults affect **new** escrows only (snapshot semantics)
- **dispute**:
  - raise dispute
  - resolve using the default resolver module (if included)
- **pause safety**
  - guardian pause works
  - timelock unpause works
#### B) Integration tests (exchange/wallet)
- verify token approvals and allowance flows
- verify event indexing (EscrowCreated / EscrowStateChanged) for backend ingestion
- verify “pull fallback” behavior (claimable balances) if push transfer fails

#### C) Performance / gas checks (recommended)
- Use Foundry to benchmark gas for core paths:

```bash
forge test --match-path "test/foundry/core/*.t.sol" --gas-report
```

- For focused micro-benchmarks, add a small Foundry test that calls:
  - `createEscrow(...)`
  - `releaseEscrowTransfer(...)`
  - `withdraw(...)` (claim path)
and capture gas deltas across commits.

### Deployed contracts index (Base Sepolia)
- **Network**: Base Sepolia
- **chainId**: 84532
- **Explorer**: Basescan (`https://sepolia.basescan.org`)

| Contract | Description | Address | Explorer |
|---|---|---|---|
| `SewToken` | Governance token used for voting | `0x7428c13e158ab6eB3E9e7780f05d58181172Ab5A` | `https://sepolia.basescan.org/address/0x7428c13e158ab6eB3E9e7780f05d58181172Ab5A` |
| `TimelockController` | Governance timelock (executes queued proposals) | `0xF0f2134CB24296781ABCa41A536c7C17600a7E47` | `https://sepolia.basescan.org/address/0xF0f2134CB24296781ABCa41A536c7C17600a7E47` |
| `GovGovernor` | On-chain Governor (absolute quorum) | `0xaFf6b4b8cF3bBDa62d4A40839c6c8244aacAC166` | `https://sepolia.basescan.org/address/0xaFf6b4b8cF3bBDa62d4A40839c6c8244aacAC166` |
| `Safe_Multisig` | Safe multisig (testnet; may be same as guardian) | `0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC` | `https://sepolia.basescan.org/address/0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC` |
| `GuardianSafe` | Guardian multisig (testnet; may be same as governance safe) | `0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC` | `https://sepolia.basescan.org/address/0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC` |
| `YieldOps` | Yield ops router (yield deposit/withdraw orchestration) | `0xFf1AaC122A1Ab02aA76E43Cf8641A4a33277C653` | `https://sepolia.basescan.org/address/0xFf1AaC122A1Ab02aA76E43Cf8641A4a33277C653` |
| `DisputeOps` | Dispute ops router (dispute flow orchestration) | `0x5456edb1f266D6F3FaeAfFa4be33a7891eC9b3D2` | `https://sepolia.basescan.org/address/0x5456edb1f266D6F3FaeAfFa4be33a7891eC9b3D2` |
| `SettlementOps` | Settlement ops router (release/cancel/settlement orchestration) | `0x1d0BE2d3b91A26537b5A8d75Ae721dE5Ea1a4054` | `https://sepolia.basescan.org/address/0x1d0BE2d3b91A26537b5A8d75Ae721dE5Ea1a4054` |
| `CreateOps` | Create ops router (escrow creation orchestration) | `0x7816EB2022B7AFB3A53a41eaa5ED5a2c3924De3b` | `https://sepolia.basescan.org/address/0x7816EB2022B7AFB3A53a41eaa5ED5a2c3924De3b` |
| `BondCollector` | Bond/fee collector helper (as configured) | `0x0f0526297983260fa92e71149322f13d74B4Cdca` | `https://sepolia.basescan.org/address/0x0f0526297983260fa92e71149322f13d74B4Cdca` |
| `ModuleManagementContract` | Slow-lane module default management | `0xaa0Fa9C11af77E7f2BF14f86C17C8436370F0a86` | `https://sepolia.basescan.org/address/0xaa0Fa9C11af77E7f2BF14f86C17C8436370F0a86` |
| `EscrowAdminContract` | Slow-lane admin helper (holds minimal admin role) | `0x34fF47Ee2f95C35ec1e012DdD2D7394D7C644931` | `https://sepolia.basescan.org/address/0x34fF47Ee2f95C35ec1e012DdD2D7394D7C644931` |
| `EscrowVault` | Core escrow contract | `0xBcDefBdEEA5C00f128bE83534646427b7248c5F9` | `https://sepolia.basescan.org/address/0xBcDefBdEEA5C00f128bE83534646427b7248c5F9` |

### Optional modules (deploy if needed)

| Contract | Description | Deploy tag | Address |
|---|---|---|---|
| `DefaultReleaseStrategy` | Default release strategy module (`contracts/modules/DefaultReleaseStrategy.sol`) | `release-strategy` | `0x9738584Db6D171e6BE9d0F104aAbF4C1cAd0fb3b` |

### What to tell the exchange partner (prepared message template)
Subject: Base Sepolia escrow integration — testnet contract addresses + scope

Hi <Name/Team>,

We’ve deployed a **Base Sepolia testnet** instance of the Sew Protocol escrow contracts for integration testing.

- **Network**: Base Sepolia (chainId 84532)
- **Purpose**: integration testing only (wallet + exchange flows). **Not production**, not a commitment to final mainnet addresses or parameters.
- **Stability**: we may redeploy and/or swap modules as we iterate. If we redeploy, we’ll provide an updated address list and a cutover date/time.

Contracts (Base Sepolia):
- See **“Deployed contracts index (Base Sepolia)”** in this guide.

Notes / disclaimers:
- **Testnet only**: tokens are not valuable; balances/roles may be reset.
- **Known differences from production**: simplified multisig/guardian setup for testnet; absolute quorum configuration for testing.
- **Event ingestion**: your indexer should listen for `EscrowCreated` and `EscrowStateChanged` on EscrowVault.

If you share your intended integration flow (deposit → escrow creation → release/cancel/dispute), we’ll run it end-to-end and align on any required event fields or edge cases.

Thanks,
<You>

### How to treat this testnet release (recommendation)
- Treat it as an **integration test deployment** with an explicit assumption you may redeploy.
- If changes are needed:
  - **Prefer module swaps** (where supported) to preserve continuity.
  - If a core contract change is needed, do a **fresh deployment** and provide a clean address list (testnet partners generally prefer clarity over “upgrades”).

