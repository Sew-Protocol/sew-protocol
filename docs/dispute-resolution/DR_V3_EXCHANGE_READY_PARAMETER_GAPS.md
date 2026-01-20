# DR v3 “Launch‑Safe Defaults” — Exchange‑Ready Gap List (Docs‑Only)

**Purpose:** Provide a diligence-safe, copy/paste checklist of what is **implemented vs. not implemented / not tunable / not validated**, and the **exact wording** docs should use to avoid over-claiming.

**Scope:** DR v3 parameters & economics (mixed bonds, staking/slashing, deadlines), plus the fee parameters that interact with dispute flows.

**Non-goal:** This document does **not** propose code changes.

---

## A) Current implementation snapshot (so reviewers know what’s real)

### A.1 Mixed bond model (oracle-free)
- **Enforced composition**: **≥ 80% stablecoin / ≤ 20% SEW** (post-haircut)
- **Haircut**: **50%** (`SEW_HAIRCUT_BPS = 5000`)
- **SEW USD valuation in staking math**: **fixed at $1** (`sewPriceUSD = 1e18`) for oracle-free enforcement

### A.2 Unbonding delays
- **Resolvers**: 14 days  
- **Seniors**: 21 days

### A.3 Minimums + capacity gating
- **Min resolver effective bond**: $250  
- **Min senior effective bond**: $25,000  
- **Max escrow per L0 case**: `min($2,000, 4× effectiveBondUSD)`

### A.4 Objective timeouts + appeal windows
- **Accept deadline**: 30 minutes  
- **Resolve deadlines**: L0 24h / L1 48h / L2 7d  
- **Appeal windows**: L0 2d / L1 3d / L2 0

### A.5 Objective slashing schedule + caps + freezes
- **Penalties**:
  - Missed accept: 25 bps (0.25%)
  - Missed resolve: 200 bps (2%)
  - Repeat missed resolve in epoch: 500 bps (5%)
  - Reversal: 0 bps initially
- **Epoch caps**:
  - Resolver: 20% per 7‑day epoch
  - Senior: 10% per 7‑day epoch
- **Freeze durations**:
  - Severe: 72 hours
  - Repeated severe in epoch: 7 days

### A.6 SEW handling on slashing
- **Slashed staked SEW is treated as burned**:
  - Prefer supply-reducing `burn(uint256)` call when supported
  - Fallback is transfer to `0x…dEaD` (effective burn)
  - Emits `SlashedSEWHandled(workflowId, amount, supplyReduced)`

---

## B) “10/10 exchange-ready” gap checklist (what’s still missing or needs careful disclosure)

Use this as a **hard checklist**. If an item is not satisfied, use the safe wording in section C.

### B.1 Parameter tunability & governance lanes (mix/haircut/valuation)
- [ ] **Mix and haircut are governance-tunable via slow-lane** (queue/activate)  
  - **Status**: **Not implemented** (currently fixed constants).
- [ ] **SEW valuation input is market-based or oracle-driven**  
  - **Status**: **Not implemented by design** (enforcement uses a fixed $1 value for oracle-free safety).
- [ ] **Glide-path mechanism** (e.g., 20/80 → 30/70 over time) exists as governed parameters  
  - **Status**: **Not implemented** (no on-chain mechanism to shift the mix/haircut over time).

### B.2 “Validated” vs “Implemented” (release diligence)
- [ ] DR v1/v2/v3 modules have **testnet validation** with published results (tx hashes, addresses, scenario outcomes)  
  - **Status**: must be disclosed as **not yet validated** unless you have the artifacts.
- [ ] DR v1/v2/v3 modules have **simulation / chaos testing results** (adversarial scenarios, throughput/latency)  
  - **Status**: must be disclosed as **not yet validated** unless published.
- [ ] External audits cover the **activated** configuration and commit hash  
  - **Status**: must be disclosed as **pending** unless reports exist.

### B.3 Appeal-bond vs slashing-appeal “bonded” language
- [ ] Any claim that **slash appeals require posting an appeal bond** (i.e., bond is actually collected/escrowed/refunded/forfeited)  
  - **Status**: **Not fully implemented** (slash appeal bond is a parameter and recorded, but custody/collection may be incomplete depending on module path).  
  - **Action for docs**: avoid “bonded” claims unless you can show collection/custody in the relevant flow.

### B.4 Staking rewards
- [ ] Any claim that “**staking rewards exist**” (emissions, rewards rate, distribution mechanism)  
  - **Status**: **Not specified/guaranteed** by default.  
  - **Action for docs**: treat as **planned / governance-defined** unless the rewards mechanism exists on-chain and is activated.

---

## C) Exact diligence-safe wording to use in docs (copy/paste)

### C.1 Mixed bond model + haircut (implemented)
Use:

> “Resolver/Senior staking uses an oracle-free mixed bond model. Effective security is computed as `stable + (SEW × 0.5 haircut)`, and composition is enforced such that at least 80% of effective security must be stablecoin-backed and at most 20% may come from SEW (post-haircut).”

Avoid:

> “Governance can tune the SEW/stable mix and haircut over time.”

Unless B.1 tunability is implemented.

### C.2 SEW valuation (oracle-free fixed assumption)
Use:

> “For mix enforcement, SEW valuation is treated conservatively and oracle-free (a fixed $1 reference is used for the enforcement calculation). No price oracle is required for bond sizing decisions.”

Avoid:

> “SEW valuation reflects market price.”

### C.3 Slashed SEW burn treatment (implemented)
Use:

> “When SEW is slashed from resolver/senior stake, it is treated as burned (supply-reducing when the token supports `burn()`, otherwise via transfer to a dead address).”

Avoid:

> “All slashed bonds are burned.”

Because user-posted appeal bonds are not SEW by definition and are not the same mechanism.

### C.4 Fees: `yieldProtocolFeeBps` + `appealBondProtocolFeeBps` (implemented)
Use:

> “The protocol supports two bounded protocol fees: `yieldProtocolFeeBps` (charged on generated yield only) and `appealBondProtocolFeeBps` (charged when an appeal bond is posted). Defaults at launch are 30% yield fee and 0% appeal-bond fee.”

Avoid:

> “Appeal processing fees are active at launch.”

### C.5 Activation/validation language (critical for exchanges)
Use this exact sentence whenever describing DR v1/v2/v3:

> “Implemented and passing local test suites (unit/fuzz/invariants). Not yet validated on testnet or through simulation testing. Not active in the initial mainnet release. Activation requires governance module swap and applies to new escrows only due to snapshot immutability.”

### C.6 Staking rewards (not guaranteed)
Use:

> “Any staking rewards program is governance-defined and may be introduced in a later release; no staking rewards are assumed by default.”

Avoid:

> “Resolvers earn staking rewards.”

Unless there is a deployed/activated rewards mechanism.

---

## D) Where a reviewer can verify each claim (optional appendix)
- Mixed bond enforcement + haircut + minimums + capacity gating: `contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol`
- Bond valuation math: `contracts/decentralized-resolution-module/BondValuationLibrary.sol`
- Deadlines/windows: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- Slashing penalties/caps/freezes + SEW burn handling: `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol`
- Fee params (`yieldProtocolFeeBps`, `appealBondProtocolFeeBps`): `contracts/core/BaseEscrow.sol`, `contracts/YieldOps.sol`

