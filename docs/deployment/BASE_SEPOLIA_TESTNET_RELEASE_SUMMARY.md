# Base Sepolia testnet release summary (IEO integration deployment)

**Last updated:** 2026-01-19  
**Network:** Base Sepolia (chainId 84532)  
**Intent:** integration testing only (wallet + exchange flows). Not production. Addresses/roles may change.

---

## What happened (timeline)

### Governance infra + core escrow deployed
- Governance infra and core escrow contracts were deployed to Base Sepolia for an “IEO-style” integration deployment.
- The canonical deployment instructions and address index live in:
  - `BASE_SEPOLIA_CORE_TESTNET_GUIDE.md`
  - `deployed.md`

### Release strategy module deployed
- `DefaultReleaseStrategy` was deployed to Base Sepolia:
  - Address: `0x9738584Db6D171e6BE9d0F104aAbF4C1cAd0fb3b`
  - Verified source on Basescan.

### Deployment snapshot artifacts added
- A machine-readable deployment report is generated at:
  - `deployments/baseSepolia/reports/version-report.json`
- A sources verification helper exists at:
  - `scripts/verify-base-sepolia-sources.ts`

---

## What’s currently “released” on Base Sepolia

### Canonical address lists
- **Human index**: `docs/deployment/deployed.md`
- **Guide + index table**: `docs/deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md`

### Deployment artifacts (hardhat-deploy)
- `deployments/baseSepolia/*.json` (one per contract)
- `deployments/baseSepolia/solcInputs/*.json` (compiler input snapshots)
- `deployments/baseSepolia/reports/version-report.json` (generated)

### Git snapshots / tags
- `deployed-baseSepolia-2026-01-19`
- `deployed-baseSepolia-2026-01-19-release-strategy`

---

## How to validate the release (recommended commands)

### Smoke test (escrow flows)
- Script:
  - `scripts/testnet/smoke-escrow.sh`
  - `scripts/testnet/smoke-escrow.ts`

### Version report (ERC-165/module metadata probing)

```bash
pnpm hardhat run --network baseSepolia scripts/verify-base-sepolia.ts
```

Output:
- `deployments/baseSepolia/reports/version-report.json`

### Source verification (Basescan)

```bash
pnpm hardhat run --network baseSepolia scripts/verify-base-sepolia-sources.ts
```

---

## Known issues / gaps in the current testnet deployment

### 1) Default module swapping is effectively disabled on the deployed escrows
**Impact:** you cannot switch defaults (release strategy / resolution / yield modules) for `EscrowVault` post-deploy.

**Root cause (design + wiring):**
- `ModuleManagementContract.queueDefaultModule/activateDefaultModule` require `msg.sender == escrowContract`.
- The escrow wrappers that would call these were removed from `EscrowVault` to save bytecode (and the escrow has no “module management setter”).

**Result:** `ModuleManagementContract` is effectively read-only defaults for the deployed escrows.

### 2) Escrow fee was initially 0 bps (not 1%) and requires slow-lane activation to change
**Status:** queued to 100 bps via slow lane on 2026-01-19.

- Queue script: `scripts/testnet/set-escrow-fee-100.ts`
- Activate script: `scripts/testnet/activate-escrow-fee.ts`

**Operational note:** on public testnets, slow lane is time-gated by `block.timestamp` and cannot be “fast-forwarded” by changing keys.

### 3) Aave yield module integration is blocked by custody / `msg.sender` mechanics
**Impact:** `AaveYieldGenerationModule` cannot safely deposit/withdraw yield under the current token custody flow without architectural changes.

**Recommended short-term stance:** keep yield disabled on testnet integration unless/until the Aave custody fix is deployed and tested.

### 4) Verification ergonomics are mixed (some contracts “bytecode mismatch”)
**Observed:** `SewToken`, `GovGovernor`, `EscrowAdminContract` report bytecode mismatch under the current local build when using `verify:verify`.

**Most likely cause:** deployed bytecode was built with compiler settings (viaIR/optimizer runs/evmVersion) that differ from the current local artifacts.

**Mitigation:** use the `deployments/baseSepolia/solcInputs/*` snapshots as the source-of-truth for verification reproduction, and avoid changing compiler settings mid-stream for the same network release line.

---

## Options for paths forward

### Option A (lowest disruption): keep current addresses; accept slow-lane delays
- Wait for queued `escrowFee=100` to become activatable.
- Continue exchange/wallet integration testing using existing EscrowVault address.
- Avoid module swap testing (not possible with current wiring).

**Pros:** no partner address changes, minimal operational churn.  
**Cons:** cannot iterate on defaults/modules; slow-lane delays block rapid iteration.

### Option B (recommended for testnet iteration): do a “vNext” testnet redeploy with swap + fast-lane tools
- Redeploy a new `EscrowVault` (new address) that includes minimal wrappers to call `ModuleManagementContract` for default swaps.
- Deploy a chainId-gated `TestnetFastLaneAdmin` contract (testnet-only) and grant it `ROLE_ADMIN_CONTRACT` on the testnet escrow(s) to permit instant parameter updates.

**Pros:** fast iteration and realistic swap testing without waiting 7 days.  
**Cons:** new address list; requires partner cutover coordination.

### Option C (post-testnet stabilization): freeze testnet, focus on mainnet readiness
- Treat Base Sepolia as a fixed “reference deployment” and stop modifying parameters.
- Shift to auditing, runbook drills, and mainnet deployment rehearsals.

**Pros:** stability for partners, easier comms.  
**Cons:** slower iteration; defects requiring redeploy become more expensive.

---

## Recommendations

### Recommended next release on Base Sepolia (if still iterating)
- Choose **Option B** and make the release explicit: “Base Sepolia IEO vNext”.
- Include:
  - escrow module-swap wrappers (release strategy first, then resolution/yield)
  - a testnet-only fast-lane admin (chainId-gated)
  - a single canonical address list + cutover note for partners

### Recommended doc/process discipline
- Keep `docs/deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md` as the canonical narrative runbook.
- Keep `docs/deployment/deployed.md` as the canonical human address index.
- Keep `deployments/baseSepolia/reports/version-report.json` as the canonical machine snapshot (regenerate per release).
- Tie every testnet release to an annotated git tag and include the tag name in the partner message.

---

## Related documents (entrypoints)

### Base Sepolia deployment + addresses
- `docs/deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md`
- `docs/deployment/deployed.md`
- `docs/deployment/RELEASES.md`
- `docs/deployment/ieo/IEO_RELEASE_GUIDE.md`

### Module swapping policy (append-only rules)
- `docs/reference/MODULE_SWAPPING_STRATEGY.md`

### Verification + integrity
- `scripts/verify-base-sepolia.ts` (version-report generation)
- `scripts/verify-base-sepolia-sources.ts` (verify sources)
- `docs/deployment/BASE_SEPOLIA_DEPLOYMENT_GUIDE.md`

### Interface/versioning
- `docs/reference/INTERFACE_VERSIONING.md`
- `docs/reference/INTERFACE_ID_ANALYSIS.md`

### Testing
- `scripts/testnet/smoke-escrow.sh`
- `docs/more/test/INITIAL_SIMULATION_TESTING_PLAN.md`

