# SEW Tokenomics (Exchange Draft)
**Document purpose:** Exchange-facing overview of **SEW** token mechanics and utility for IEO diligence.  
**Explicit scope:** **No allocations / vesting / distribution schedule** (intentionally excluded).  
**Source-of-truth rule:** On-chain behavior (contracts) overrides narrative docs.

---

## 1) Token identification
- **Token name (intended):** `Sew Token`
- **Ticker (intended):** `SEW`
- **Standard:** ERC-20 + governance voting extensions (OpenZeppelin `ERC20Votes`)
- **Decimals:** 18 (OpenZeppelin ERC20 default)
- **Primary purpose:** Governance voting; additionally, SEW is referenced as the protocol token used in decentralized dispute-resolution staking (DR v3 design).

**Implementation reference:** `contracts/token/SewToken.sol`

---

## 2) Supply model (fixed supply)
### 2.1 Fixed total supply
SEW is designed as a **fixed supply token**:
- **Minting occurs once** in the constructor via `_mint(initialOwner, initialSupply)`.
- There is **no public/external mint function** in `SewToken`.

### 2.2 Intended mainnet supply
**Intended fixed supply:** **1,000,000,000 SEW** (18 decimals), i.e.:
- `initialSupply = 1_000_000_000 * 10^18`
- Raw units string used in config defaults: `1000000000000000000000000000`

**Important diligence note:** `initialSupply` is a **constructor argument** in deployment scripts/config. The exchange should verify the deployed token’s on-chain `totalSupply()` equals 1B * 1e18 and matches the verified constructor args.

**Implementation/deploy references:**
- `contracts/token/SewToken.sol`
- `deploy/20_gov_token.ts`
- `deploy/_config.ts` and `config/governance.config.ts`

---

## 3) Governance utility (current)
SEW is used for **token-weighted governance voting** via OpenZeppelin Governor:
- Governance contract integrates `GovernorVotes` (token voting power) and `GovernorTimelockControl` (execution through timelock).
- Voting power requires delegation (standard ERC20Votes behavior).

**References:**
- `contracts/token/SewToken.sol`
- `contracts/governance/GovGovernor.sol`

---

## 4) Economic utility beyond governance (protocol modules)
This section describes **economic usage patterns** for SEW within protocol modules. Some modules are staged for later rollout; claims should be categorized as **Current (initial mainnet)** vs **Planned (future swap-in)** during finalization.

### 4.1 Resolver staking (DR v3 design)
In DR v3 staking design, resolver bonds are intended to be a **mix of stablecoin + SEW**:
- Bond mix constraints target **≥ 80% stablecoin** and **≤ 20% SEW** (effective composition).
- SEW portion is haircut by **50%** when computing effective bond value (conservative risk treatment).
- SEW is valued at a **fixed $1 assumption** for bond calculations (oracle-free, conservative; not market-priced).

**Implementation reference:** `contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol`

**Implications for SEW tokenomics:**
- Creates potential **structural demand** for SEW by resolvers (to satisfy bond composition up to the cap).
- SEW is **custodied while bonded** (held by the staking contract), affecting circulating liquidity for those participants.
- The bond design is **oracle-free** and anchored primarily by stablecoin collateral; SEW provides alignment without becoming a single point of failure (see `docs/dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md`).

### 4.2 Slashing (DR v3 design)
Slashing can slash both the stablecoin and SEW components of resolver bonds (as returned by the staking module’s `slash()` / `slashCoverage()`).

**SEW burn treatment:**
- When SEW is slashed from resolver/senior bonds, it is treated as **burned** (deflationary sink), not retained as protocol revenue.

**Implementation references:**
- `contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol` (slashes transfer both stable + SEW to slashing module)
- `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol`
- `contracts/decentralized-resolution-module/InsurancePoolVault.sol` (stable-token insurance pool)

---

## 5) Protocol fees & revenue (not necessarily SEW-denominated)
Protocol fees are primarily charged on escrowed assets (any ERC20), not necessarily in SEW:
- Escrow fee: configurable (default 1% in docs), charged at escrow creation and routed to `escrowFeeAddress`.
- Appeal bond fees: not implemented in DR v2 (bonds are refunded in full on success or paid in full to resolvers on failure).

**Doc reference:** `docs/FEE_IMPLEMENTATION_SUMMARY.md`  
**Implementation reference:** `contracts/core/BaseEscrow.sol` (fee), DR incentive modules for bond handling.

**Tokenomics implication:** These mechanisms create protocol revenue, but **do not directly create SEW buy pressure** unless governance explicitly routes revenue to acquire SEW or uses SEW for fees (not assumed here).

---

## Protocol Fees & Economic Design

This section describes how the protocol may collect fees, the rationale for those fees, and how they align with user expectations in escrow-based systems. The protocol is designed to function fully **independently of fee activation**, with all fees explicitly defined, bounded, and governance-controlled.

---

### Design Context: Escrow Comes First

In traditional escrow systems:

* Users pay fees for protection and dispute resolution
* Funds held in escrow do **not** generate interest
* Any yield generated during escrow is typically retained by the operator

In contrast, this protocol:

* Provides escrow and dispute resolution as its primary function
* Optionally enables yield generation on escrowed funds
* Shares the majority of that yield with users

Yield is therefore **additive** and **non-essential**. Users are strictly better off than with traditional escrow, even when protocol fees are applied.

---

### 1. Yield Protocol Fee (Active)

When a yield generation module is enabled, the protocol collects a **Protocol Fee on generated yield only**.

* **Fee base:** Yield only (never escrow principal)
* **Applicability:** Only when yield generation is enabled
* **Configurability:** Set in basis points (`yieldProtocolFeeBps`)
* **Fallback:** If yield generation is disabled or fails, escrow execution is unaffected and no fee is collected

**Current parameters**

* Protocol yield fee: **30% of generated yield**
* User share: **70% of generated yield**
* Escrow principal: **100% untouched**

**Rationale**

* Yield is not the reason users engage with the protocol
* Yield represents upside that users would not receive in traditional escrow
* The protocol’s share funds security, dispute infrastructure, and long-term maintenance

**Constraints**

* The protocol yield fee is capped by governance-defined limits
* Any change to the fee is subject to governance approval and timelock
* The fee can be set to 0% by governance at any time

---

### 2. Appeal Protocol Fee (Implemented, Inactive at Launch)

Dispute escalation may require the posting of appeal bonds. A **Protocol Appeal Fee** is implemented and can be activated in future releases to cover the operational cost of dispute escalation and coordination.

* **Status:** Inactive at launch (defaults to 0%)
* **Nature:** Non-refundable appeal processing fee (charged when an appeal bond is posted)
* **Fee base:** Percentage of the appeal bond
* **Configurability:** Set in basis points (`appealBondProtocolFeeBps`)
* **Scope:** Applied only when an appeal is initiated

**Indicative future parameters**

* Expected range: 2–10% of the appeal bond
* Activation: Requires explicit governance approval and timelock

When inactive, appeal bonds are refunded or distributed in full according to dispute outcomes.

---

### 3. Governance, Timelocks, and Safety

All protocol fees are:

* Explicitly defined on-chain
* Bounded by immutable maximums
* Controlled by DAO governance
* Subject to extended timelock delays for economic changes

Fee-related changes (including yield and appeal fees) require:

* Governance approval
* Public notice via on-chain proposals
* A timelock sufficient to allow users to opt out before changes take effect

Emergency or fast-track governance paths **cannot** be used to increase protocol fees.

---

### 4. Transparency and Auditability

The protocol emits on-chain events for:

* Fee parameter changes
* Fee accrual
* Fee withdrawals

All protocol fees are independently verifiable by users, auditors, and exchanges.

---

### Summary

| Fee Type            | Applies To           | Status at Launch | User Impact                      |
| ------------------- | -------------------- | ---------------- | -------------------------------- |
| Yield Protocol Fee  | Generated yield only | Active (30%)     | Users receive majority of upside |
| Appeal Protocol Fee | Appeal bonds         | Inactive (0%)    | No impact at launch              |

The protocol remains fully functional with all protocol fees set to zero.

---

## 6) Admin/governance surface (exchange diligence)
Exchanges typically assess “who can change what, how fast”:
- SEW itself is not upgradeable in this repo (simple constructor-based deployment), but ownership exists (`Ownable`) and is intended to be transferred to Safe → Timelock.
- Protocol modules/parameters are governed via timelock + “slow lane” pattern (queue/activate with delays) per docs; validate in code for each module surfaced in this document.

**References:**
- `contracts/token/SewToken.sol` (ownership)
- `contracts/governance/GovGovernor.sol` (timelocked governance)
- `docs/token/2026_token_expectations.md` (expectations checklist)

---

## 7) Out of scope (explicit)
The following are intentionally excluded from this draft:
- Allocations tables (team/investors/treasury/etc.)
- Vesting schedules and lockups
- Circulating supply schedule at TGE

---

## 8) Verification checklist (for the exchange)
- Confirm verified contract bytecode for `SewToken` matches `contracts/token/SewToken.sol`.
- Verify on-chain:
  - `name()` == expected
  - `symbol()` == expected (`SEW`)
  - `decimals()` == 18
  - `totalSupply()` == `1_000_000_000 * 10^18`
  - No callable `mint()` function exists on the deployed token
- Confirm current owner and governance control plan (Safe + Timelock) and the timelock delay.

---

## 9) Known gaps / reconciliation items (must resolve before sending to an exchange)
These are items where **docs, code, and/or tests currently disagree** or where an exchange diligence reviewer is likely to ask follow-ups.

### 9.1 Symbol configuration mismatch risk
Deployment config defaults the token symbol to `$EW`, while this document intends `SEW`. Mainnet deployment should explicitly set `GOVERNANCE_TOKEN_SYMBOL=SEW` and the exchange should verify the deployed `symbol()` on-chain.

### 9.2 Safe deployment script is a placeholder
`deploy/10_safe.ts` stores placeholder values unless Safe contracts tooling is installed and used. For an exchange package, provide the **actual Safe address** and signing policy (owners, threshold) as deployed on the target chain.

### 9.3 Appeal bond “processing fee / protocol cut” is not implemented (DR v2)
The protocol supports an appeal bond protocol fee parameter (`appealBondProtocolFeeBps`) but it defaults to **0% at launch**. When set to 0, bonds are refunded/distributed in full; when >0, the protocol fee is deducted when the bond is posted.

### 9.4 SEW pricing in staking math: docs vs code
The bond valuation documentation describes a `sewPrice` input. In `ResolverStakingModuleV1`, SEW is valued using a constant `$1` assumption (oracle-free). This must be clearly labeled in any published economic description.

### 9.5 Slashing appeal bond is recorded but not collected
`ResolverSlashingModuleV1.appealSlash()` records an `appealBond` amount but does not transfer/escrow any funds for the appeal. If appeals are meant to be anti-spam bonded, this is a gap to resolve or explicitly disclose.

### 9.6 Slashed SEW handling is unclear
`ResolverStakingModuleV1` transfers slashed SEW to the slashing module, but `ResolverSlashingModuleV1` distributes only the stable-token component. Decide and document whether slashed SEW is:
- intentionally retained/locked (a sink), or
- intended to be routed to treasury/insurance/counterparty and needs implementation.

### 9.7 Counter-party distribution not implemented in slashing
Design docs mention counter-party compensation from slashes. Current code sets counter-party share to 0 (and lacks counter-party identification logic). This affects “user protection” claims.

---

## 10) Reconciliation matrix (source mapping)
See: `docs/token/SEW_TOKENOMICS_RECONCILIATION_MATRIX.md`

