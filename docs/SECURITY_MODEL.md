# Sew Protocol — Security Model

> **Audience:** Security researchers, auditors, protocol reviewers, integration partners.
>
> **Scope:** This document covers the complete security posture of the Sew Protocol:
> threat model, trust assumptions, access control architecture, defensive coding patterns,
> economic security, emergency controls, and residual risk. It is derived from the
> contract source; any discrepancy between this document and the contracts is a
> documentation bug.
>
> **Related documents:**
> - [`docs/governance/GOVERNANCE_CONSTRAINTS.md`](governance/GOVERNANCE_CONSTRAINTS.md) — hard bounds on every governance parameter
> - [`docs/governance/governance.md`](governance/governance.md) — governance model and operational runbooks
> - [`docs/security/SECURITY_MODEL.md`](security/SECURITY_MODEL.md) — original per-escrow isolation reference
> - [`docs/dispute-resolution/DISPUTE_ECONOMICS.md`](dispute-resolution/DISPUTE_ECONOMICS.md) — bond, slashing, and incentive mechanics

---

## 1. Security philosophy

Sew Protocol is a containment layer for protected transfers. It does not attempt to
eliminate all forms of risk; instead it applies three principles throughout the design:

| Principle | What it means in practice |
|-----------|---------------------------|
| **Containment over prevention** | Failures are expected. The design limits blast radius so that a compromise of one component does not cascade into others. |
| **Determinism over discretion** | Funds move according to rules fixed at creation time — not according to human judgment exercised later. |
| **Isolation over shared risk** | Each escrow is an independent agreement. Its modules, fees, timeouts, and resolution path are frozen at creation and cannot be altered by any subsequent governance action. |

---

## 2. Threat model

The protocol is designed to operate in a fully adversarial environment. The following
threats are explicitly modelled.

### 2.1 User-level threats

| Threat | Mitigation |
|--------|-----------|
| Sender releases funds to wrong party | Recipient must explicitly accept the transfer before release is permitted |
| Premature or unauthorized release | Release authorization is delegated to a snapshotted `releaseStrategy` module; the release path requires it to pass |
| Duplicate or replay disputes | One active dispute per escrow; dispute state is checked before any new dispute is opened |
| Griefing via frivolous disputes | Minimum escrow value threshold (`setMinDisputeEscrowValue`); per-sender dispute rate cap (`setMaxDisputesPerSenderPerDay`); escalation cooldown (`setEscalationCooldown`); escalation bond cost curve (quadratic by default) deters repeated fruitless appeals |

### 2.2 Counterparty / resolver threats

| Threat | Mitigation |
|--------|-----------|
| Fraudulent dispute decision | Multi-round escalation pipeline (initial → senior → Kleros); losing party can appeal at each round |
| Resolver collusion | Bond-backed accountability; EMA reputation scoring; capacity gating limits per-resolver exposure |
| Resolver liveness failure (timeout) | Resolver is slashed (0.25% bond for missed accept, 2% for missed resolve, 5% repeat); dispute is reassigned; escalation path to senior resolver if failures persist |
| Resolver stake withdrawal during active dispute | Unbonding requires a 14-day (resolver) / 21-day (senior) delay; stakes locked to an active dispute cannot be unbonded until the dispute finalises |
| Senior resolver capture | Senior resolvers are DAO-appointed; removal requires governance; Kleros is the final backstop for decisions at senior level |

### 2.3 Smart contract threats

| Threat | Mitigation |
|--------|-----------|
| Reentrancy | `nonReentrant` modifier on every external state-mutating function in `BaseEscrow` and all ops contracts; `ReentrancyGuard` from OpenZeppelin |
| Deflationary / fee-on-transfer tokens | Balance-before / balance-after accounting on every `transferFrom` (see §5) |
| Unsafe ERC-20 (missing return values) | `SafeERC20` used everywhere; no raw `.transfer()` or `.transferFrom()` calls |
| Integer overflow / underflow | Solidity 0.8 built-in overflow checks; explicit `BalanceUnderflow` guard in `_updateEscrowBalance` |
| Incorrect fee accounting | `_recordFee` has overflow protection; `MAX_FEE_BPS` constants enforced in all setters |
| Module substitution attack | Modules are snapshotted per-escrow at creation; no function can change a snapshotted module address for an existing escrow |
| Yield integration failure (Aave) | Slippage protection (0.1% tolerance); emergency fallback via `emergencyUnwind`; Guardian can disable Aave without governance delay |
| Recovery calculation error | `recoverERC20` validates against `available` excess (not total balance); `getAccountingDelta` / `reconcileAccounting` provide reconciliation |
| Batch gas DoS | `MAX_BATCH_SIZE = 50` enforced on all batch operations |

### 2.4 Governance threats

| Threat | Mitigation |
|--------|-----------|
| Malicious module swap targeting existing escrows | Snapshot isolation — module swaps apply only to new escrows; existing `ModuleSnapshot` records are immutable |
| Rogue Guardian expanding protocol risk | Guardian role is strictly down-only (cannot unpause, raise caps, resume yield, cancel proposals); encoded in `onlyRole(ROLE_GUARDIAN)` access control |
| Governance vote capture (whale attack) | Proposal threshold: 10,000,000 SEW (1% of supply); quorum: 4,000,000 SEW; votes must pass two on-chain delays (48h Timelock + 7d Slow lane for module swaps) |
| Emergency action without delay | Guardian emergency actions are limited to risk reduction (pause, lower caps, disable Aave); unpause requires 48h Timelock |
| DAO address change post-deployment | `queueDao()` / `activateDao()` were removed; DAO address is set in the constructor and is permanently immutable |

### 2.5 Economic / MEV threats

| Threat | Mitigation |
|--------|-----------|
| Flash loan manipulation of resolver bond valuation | Bond composition enforced at check time, not at deposit time; `BondValuationLibrary.simulatePriceCrash` models stress scenarios during governance review |
| Appeal bond sniping | Appeal window is a fixed on-chain deadline; no off-chain component |
| Capacity manipulation (low-bonded resolver accepting high-value dispute) | Capacity gate: `maxEscrowPerCase = min($2,000, 4 × resolverBond)`; resolver cannot be assigned a dispute exceeding their capacity |
| Slashing cliff (single large slash drains bond) | Per-epoch slash caps: 20% per 7-day epoch for timeout offenses, 10% for fraud offenses; per-slash maximum enforced by `MAX_SLASH_PER_OFFENSE = 50%` |

### 2.6 Validator / liveness threats

| Threat | Mitigation |
|--------|-----------|
| Validator censorship of release transactions | Multiple independent release paths: sender, recipient, keeper (`ROLE_KEEPER`), resolver, timed automation |
| Governance execution deadlock | TimelockController uses open execution (`EXECUTOR_ROLE = address(0)`) — anyone can execute a matured proposal; prevents deadlock if the original proposer becomes unavailable |
| Indefinite pause lockout | Pause duration is bounded by contract constants (`MAX_PAUSE_DURATION`, `MAX_PAUSE_CYCLES`); unpause requires 48h Timelock governance |

---

## 3. Trust assumptions

### 3.1 Trusted

The protocol makes the following trust assumptions. Violation of any of these would
compromise the stated security guarantees.

| Actor / component | What is trusted |
|---|---|
| Ethereum L1 | Finality, correct execution of EVM opcodes, correct block.timestamp within ~15-second tolerance |
| OpenZeppelin contracts (`AccessControl`, `TimelockController`, `ReentrancyGuard`, `SafeERC20`, `GovernorTimelockControl`) | Correct implementation of the stated interfaces; version pinned in dependencies |
| TimelockController | Enforces minimum delay; proposer/executor/canceller roles correctly gate proposal lifecycle |
| GovernorTimelockControl | Enforces proposal threshold and quorum; routes proposals through TimelockController |
| SEW token contract | Correct ERC-20 implementation; no hidden mint or transfer-hook logic that could bypass accounting |
| Governance process integrity | DAO proposals are correctly evaluated before being passed; social-layer governance is out of scope for the contract security model |

### 3.2 Not trusted (explicitly untrusted or threat-modelled)

| Component | Why untrusted |
|---|---|
| Individual resolvers | May collude, miss deadlines, or post incorrect decisions — modelled and handled via bonds, slashing, EMA scoring, and multi-round escalation |
| Senior resolvers | Higher accountability than initial resolvers but still modelled as potentially biased; Kleros is the final backstop |
| Kleros arbitration layer | Trusted for finality at the Kleros round only; prior-round decisions may be wrong and are expected to be overturned via the appeal mechanism |
| External yield protocols (Aave v3) | Treated as potentially failing; slippage protection and emergency fallback paths exist; Guardian can disable without delay |
| Guardian multisig signers individually | Multisig requires threshold of signers; individual signer compromise only reduces risk (cannot expand it) |
| Module implementations added post-deployment | Each new module is a new trust boundary; governance vetting is required before queue/activation |
| Frontend / RPC infrastructure | Out of scope for the contract security model; users should verify contract addresses on-chain |

### 3.3 External dependencies

| Dependency | Usage | Risk profile |
|---|---|---|
| Aave v3 | Yield generation for escrow principal | Optional; Guardian can disable; slippage + emergency unwind fallback |
| Kleros arbitration | Round 2 (final) dispute resolution | Kleros liveness and correctness are trusted for terminal decisions only |
| Chainlink / price oracle | Bond valuation (`BondValuationLibrary`) for SEW/USD pricing | Oracle manipulation is modelled; haircut and composition rules limit impact |

---

## 4. Access control architecture

### 4.1 Roles

| Role | Assigned to | Powers | Cannot |
|---|---|---|---|
| `ROLE_TIMELOCK` | `TimelockController` | Execute all Standard and Slow lane governance functions | Execute emergency-lane functions (`ROLE_GUARDIAN`) |
| `ROLE_GUARDIAN` | Guardian multisig | Pause, disable Aave, lower caps (all down-only) | Unpause, raise caps, swap modules, cancel proposals |
| `ROLE_ADMIN_CONTRACT` | `EscrowAdminContract` | Configure operational parameters within bounds (timeouts, fees, attachments) | Act outside predefined bounds; change existing escrow state |
| `ROLE_KEEPER` | Keeper EOA or contract | Trigger timed automations (`automateTimedActions`) | Rewire any protocol ops; change any configuration |
| `ROLE_FEE_RECIPIENT` | Fee recipient address | Withdraw accrued protocol fees | Govern anything |
| `ROLE_ESCROW_CONTRACT` | Registered escrow contracts | Interact with ops contracts (CreateOps, SettlementOps, DisputeOps, YieldOps) | Register new escrow contracts themselves |
| `DEFAULT_ADMIN_ROLE` | `TimelockController` (transferred at deployment) | Grant / revoke roles | — (held by Timelock, so role changes require governance) |

### 4.2 TimelockController hardened posture

| Role on Timelock | Assigned to | Rationale |
|---|---|---|
| `PROPOSER_ROLE` | Governor only | Only the DAO can queue proposals |
| `EXECUTOR_ROLE` | `address(0)` (open) | Anyone can execute a matured proposal — prevents execution deadlock |
| `CANCELLER_ROLE` | Governor only | Guardian cannot cancel queued proposals; only the DAO can cancel its own proposals |
| `TIMELOCK_ADMIN_ROLE` | TimelockController itself | Self-admin only; no external admin after deployment |

### 4.3 Role separation guarantees

- TimelockController does not hold `ROLE_GUARDIAN` → cannot execute emergency actions.
- Guardian does not hold `PROPOSER_ROLE` / `EXECUTOR_ROLE` on TimelockController → cannot
  queue or execute governance proposals.
- `ROLE_KEEPER` is limited to timed-automation triggers — no configuration functions are
  exposed to it.
- `ROLE_FEE_RECIPIENT` has no governance authority whatsoever.
- `DEFAULT_ADMIN_ROLE` is surrendered to the Timelock at deployment; no EOA retains it.

---

## 5. Defensive coding patterns

### 5.1 Reentrancy

Every external function in `BaseEscrow` that mutates state uses OpenZeppelin's
`nonReentrant` modifier. This applies to:

- `createEscrow` / `createEscrowTransfer`
- `release`, `recipientCancel`, `senderCancel`
- `raiseDispute`, `resolveDisputeByTimeout`, `automateTimedActions`
- `executePendingSettlement`, `proposeSplit`, `acceptSplit`, `cancelSplit`
- `claimBondProtocolFees`, `claimExcessEthRefund`
- All ops contract entry points

Where Slither static analysis flags a suppressed warning (`slither-disable-next-line
reentrancy-no-eth`), the suppression is documented and the affected code was manually
verified to follow checks-effects-interactions with no ETH transfer risk.

### 5.2 Token transfer safety

- All ERC-20 operations use `SafeERC20.safeTransfer` / `safeTransferFrom`.
- Deflationary and fee-on-transfer tokens are handled via balance-before / balance-after
  accounting:
  ```solidity
  uint256 balBefore = IERC20(token).balanceOf(address(this));
  IERC20(token).safeTransferFrom(sender, address(this), amount);
  uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
  ```
  The `received` amount — not the input `amount` — is used for all subsequent accounting.

### 5.3 Checks-effects-interactions (CEI)

All functions that transfer funds follow CEI strictly:

1. **Check** inputs and preconditions (revert early).
2. **Effect** all state changes (balances, status, flags).
3. **Interact** (external call / token transfer) only after state is committed.

The yield module (`AaveYieldGenerationModule`) had a prior HIGH finding (state cleared before
withdrawal confirmation) which has been resolved: state is now cleared only after a
successful withdrawal.

### 5.4 Integer arithmetic

- Solidity 0.8 built-in overflow/underflow protection on all arithmetic.
- Explicit `BalanceUnderflow` guard in `_updateEscrowBalance` as an additional defensive
  layer (documented in `SECURITY_FIXES_COMPLETED.md`).
- Fee arithmetic uses `MAX_PROTOCOL_FEE_BPS = 3000` constant to prevent fee overflow.
- Bond valuation uses `BondValuationLibrary` with fixed-point arithmetic validated against
  known edge cases.

### 5.5 Input validation

- Zero-address checks on all configuration setters that accept addresses.
- Bounds checks on all numeric parameters (see
  [Governance Constraints §4](governance/GOVERNANCE_CONSTRAINTS.md#4-parameter-bounds)).
- `InvalidConfig` custom error when timeout configuration is mutually exclusive
  (`autoReleaseTime > 0 AND autoCancelTime > 0` simultaneously is rejected).

---

## 6. Per-escrow isolation (snapshot model)

Each escrow is a fully independent agreement. At the moment `createEscrow()` executes, a
`ModuleSnapshot` is written containing:

```
resolutionModule          — dispute arbitration logic
releaseStrategy           — release authorization logic
yieldGenerationModule     — yield accrual (e.g. Aave)
yieldDistributionModule   — yield distribution logic
incentiveModule           — resolver incentive accounting
yieldProtocolFeeBps       — protocol fee on yield (frozen)
appealBondProtocolFeeBps  — protocol fee on appeal bonds (frozen)
escrowFeeBps              — creation fee (frozen)
defaultAutoReleaseDelay   — automatic release deadline (frozen)
defaultAutoCancelDelay    — automatic cancellation deadline (frozen)
maxDisputeDuration        — maximum dispute duration (frozen)
appealWindowDuration      — appeal window (frozen)
```

No function exists that can mutate any of these fields for an existing escrow. Any
governance action that changes a default module or parameter takes effect only for escrows
created after the change activates.

**Mechanical enforcement:** module getter functions (`getResolutionModule()`, etc.) read
from the snapshotted field, not from the global default. A governance actor who successfully
swapped the global default resolution module would have zero effect on any escrow created
before the swap activated.

---

## 7. Economic security

### 7.1 Resolver bond composition (DR v3)

Resolvers must post a bond before accepting disputes. The bond is subject to enforced
composition and valuation rules:

| Parameter | Constraint |
|---|---|
| Minimum stable fraction | 80% of effective bond value |
| Maximum SEW fraction | 20% of effective bond value (after haircut) |
| SEW haircut | 50% — SEW is valued at 50 cents on the dollar for bond purposes |
| Capacity gate | `maxEscrowPerCase = min($2,000, 4 × effectiveBondUSD)` |
| Unbonding delay (resolver) | 14 days |
| Unbonding delay (senior resolver) | 21 days |

The haircut means a complete SEW price crash to zero reduces a resolver's effective bond
by at most 20%, since the stable component accounts for at least 80%.

### 7.2 Slashing schedule (DR v3)

Slashed SEW is burned (transferred to `address(0xdEaD)` or `burn()`):

| Offense | Slash rate | Cap |
|---|---|---|
| Missed accept | 0.25% of bond | Per-epoch: 20% (timeout offenses) |
| Missed resolve (first) | 2% of bond | Per-epoch: 20% (timeout offenses) |
| Missed resolve (repeat) | 5% of bond | Per-epoch: 10% (fraud offenses) |
| Per-slash absolute maximum | 50% of bond | — |

Slash caps prevent a single coordinated epoch from draining a resolver's bond entirely.
A resolver who is already slashed for a given workflow cannot be double-slashed for the
same event (`AlreadySlashedForWorkflow` check).

### 7.3 Appeal bond economics

Each escalation round requires the appealing party to post a bond. Under the default
quadratic curve:

```
cost(k) = baseCost + stepSize × k²
```

Where `k` is the 0-indexed escalation count. Successive appeals become geometrically more
expensive. A party repeatedly appealing correct decisions will exhaust their bond balance
faster than they can win. The bond outcome:

- **Upheld (escalation was wrong):** bond forfeited to the resolver whose decision was
  validated.
- **Overturned (escalation was correct):** bond refunded to the depositor.

### 7.4 Insurance pool

`InsurancePoolVault` is a dedicated vault seeded by a portion of slashed funds. It acts as
a payer-of-last-resort when a resolver has insufficient bond to cover a valid dispute
outcome. This protects disputing parties from resolver insolvency while maintaining the
incentive alignment of the bond model.

---

## 8. Emergency controls

### 8.1 Guardian pause

The Guardian multisig can call `pause()` at any time with zero delay. The pause:

- Blocks new escrow creation.
- Disables specific operations on existing escrows depending on which function is called.
- Does **not** move any funds or change any escrow state.

Pause duration is bounded by `MAX_PAUSE_DURATION` and `MAX_PAUSE_CYCLES` constants.
An indefinite pause is not possible; recovery requires governance (48h Timelock).

### 8.2 Aave emergency controls

The Guardian can call `guardianDisableAave()` to halt all new Aave deposits without
governance delay. If an active position needs to be unwound:

1. Normal path: `withdrawWithYield()` via `YieldOps`.
2. Fallback: `emergencyUnwind()` on `AaveYieldGenerationModule` — a separate code path
   invoked automatically if the primary withdrawal reverts.
3. Guardian operations contract (`GuardianOps`) can trigger forced unwinds.

### 8.3 Exposure caps

Aave yield module enforces per-token and global USD exposure caps:

- `setTokenCap` / `setGlobalCap` — require Timelock (Standard lane, 48h).
- `guardianLowerTokenCap` / `guardianLowerGlobalCap` — Guardian immediate, but
  `newCap <= currentCap` is enforced; Guardian cannot raise a cap.

---

## 9. Upgrade security

### 9.1 No proxy upgradeability

`BaseEscrow`, `EscrowVault`, and `EscrowableERC20` are not proxy contracts. There is no
`upgradeTo()` function. Upgrading the escrow core requires deploying a new contract and
migrating users, which is a social-layer action subject to community scrutiny.

### 9.2 Module upgrade path

Modules (resolution, yield, release strategy) are upgradeable by deploying a new
implementation and swapping via Slow lane governance (~9 days wall-clock). The swap:

- Takes effect only for escrows created after `activateX()` executes.
- Cannot be reverted instantly — reversing a change costs another full delay cycle.
- Requires both `queueX()` (48h Timelock) and `activateX()` (48h Timelock) with 7 days
  between them.

### 9.3 Forward-only constraint

There is no mechanism to cancel a queued module swap. The Governor holds `CANCELLER_ROLE`
on the Timelock and could cancel a queued Timelock operation — but cannot cancel the
Slow-lane ETA once the Timelock operation has executed (i.e., once `queueX()` has fired).

---

## 10. Resolved and outstanding issues

### 10.1 Resolved (pre-launch)

All CRITICAL, HIGH, and MEDIUM priority issues identified in internal QA reviews have been
resolved. Key fixes:

| Severity | Issue | Fix |
|---|---|---|
| CRIT | Underflow risk in `_updateEscrowBalance` | Explicit `BalanceUnderflow` guard added |
| CRIT | `recoverERC20` calculation error | Validated against `available` excess, not total balance |
| CRIT | Incentive module: balance mismatch on distribution | Balance validation added before fee recording |
| CRIT | `YieldOps.recoverTokens` missing access control | `ROLE_GUARDIAN` access control added |
| HIGH | `withdrawFees` wrong state-clearing order | CEI fixed; state cleared after successful transfer |
| HIGH | Aave withdrawal: no slippage protection | 0.1% slippage tolerance check added |
| HIGH | State cleared before withdrawal confirmed in Aave | State cleared only after successful `withdraw()` return |
| HIGH | No batch size limit (gas DoS) | `MAX_BATCH_SIZE = 50` enforced |
| HIGH | Duplicate resolver recording in incentive module | Deduplication check added |
| MEDIUM | Missing zero-address validation in fee setters | Added across all setters |
| MEDIUM | Fee overflow not guarded | `MAX_PROTOCOL_FEE_BPS = 3000` constant + check |

### 10.2 Outstanding (non-security)

Only LOW-priority cosmetic / gas-optimization items remain:

- Struct packing of `EscrowTransfer` could save ~20,000 gas per creation.
- Some legacy event parameters use inconsistent naming (`workflowId` vs `id`).
- Some internal functions lack NatSpec documentation.

None of these affect security.

---

## 11. Known risks and limitations

These are accurately characterised risks — not defects.

| Risk area | Description | Severity |
|---|---|---|
| Kleros liveness | If Kleros is unavailable, a dispute at round 2 cannot be finalised until Kleros responds. A `maxDisputeDuration` cap provides an upper bound. | Medium |
| Oracle manipulation (bond valuation) | Bond valuation uses an on-chain price oracle for SEW/USD. A flash-loan oracle attack could temporarily distort the effective bond value. The haircut (50%) and composition rules (80% stable) limit the impact. | Low–Medium |
| Governance delay cannot protect against a passed malicious proposal | The 48h Timelock provides a detection window — not a guarantee. If a malicious proposal passes the DAO vote, the community has 48h to respond (for Standard lane) or ~9 days (for Slow lane). | Medium |
| Aave v3 smart contract risk | If Aave v3 itself is exploited, yield principal deposited via the Aave module is at risk. This is limited by per-token and global exposure caps. | Medium (external) |
| Pause is protocol-wide | The Guardian pause is not per-escrow. A global pause affects all escrows including those uninvolved in the triggering incident. This is an intentional design tradeoff (rapid containment vs. collateral disruption). | Low (design tradeoff) |
| Evidence module data availability | Evidence submitted on-chain is permanent; evidence submitted off-chain (IPFS pointers) relies on external storage availability for dispute resolution. | Low |

---

## 12. Security contact and disclosure

Vulnerability reports should be sent to **security@sew** and will receive an initial
response within 48 hours. We follow a 90-day coordinated disclosure policy.

See [`docs/SECURITY.md`](SECURITY.md) for the full responsible disclosure policy, scope
definition, and acknowledgement process.

---

*Last updated: May 2026*

---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `62fce3a` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually checked against `BaseEscrow.sol` (reentrancy guards, SafeERC20, CEI patterns), role constants, `ResolverSlashingModuleV1.sol` (slashing/burn), and `SECURITY_FIXES_COMPLETED.md` (all CRIT/HIGH/MED resolved). Threat model cross-referenced against known attack surfaces. Simulation covers adversarial economic scenarios (Phase F/H/AI). Formal verification of all security properties not yet complete — needs follow-up. |
