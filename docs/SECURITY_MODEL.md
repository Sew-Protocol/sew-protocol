# Security Model

**Version:** 1.0  
**Last Updated:** 2026-01-06  
**Commit:** TBD (fill at release tag)  
**Target Network:** Base Mainnet (Chain ID: 8453)

## Scope

This document defines the security model for the escrow protocol contracts, deployment infrastructure, and operational scripts.

**In Scope:**
- Core escrow contracts: `BaseEscrow`, `EscrowVault`, `EscrowableERC20`
- Resolution modules: `DefaultResolutionModule`, `DecentralizedResolutionModule`
- Resolver incentive module: `ResolverIncentiveModule` (with payment calculation libraries)
- Yield generation module: `AaveYieldGenerationModule` (optional, may be disabled at launch)
- Governance contracts: OpenZeppelin `Governor`, `TimelockController`
- Deployment scripts and governance tooling
- Operational runbooks and emergency procedures

**Out of Scope:**
- Frontend applications
- Off-chain infrastructure (IPFS, APIs)
- Third-party dependencies (Aave protocol itself, block explorers)
- Social engineering and key management practices (covered at high level)

---

## Security Goals

1. **Escrow Correctness**: Funds held in escrow are correctly tracked and cannot be double-spent or lost due to state machine errors.

2. **Immutability of In-Flight Escrows**: Once an escrow is created, its rules (modules, timeouts, resolver) cannot be changed by any actor, including governance.

3. **Bounded Governance Changes**: All governance changes are time-delayed and bounded. No governance actor can unilaterally change escrow rules for existing escrows.

4. **Safe Dispute Resolution**: Dispute resolution is handled by authorized resolvers with proper access control. Resolution logic cannot be manipulated to favor one party.

5. **Safe External Integrations**: External integrations (e.g., Aave for yield) are protected by caps, pause mechanisms, and proper accounting. Failures in external protocols do not result in fund loss.

6. **No Per-Escrow Admin Overrides**: No function exists that allows governance to modify individual escrow rules after creation.

7. **Guardian Down-Only Powers**: Emergency controls can only reduce risk, never increase it. Guardian cannot unpause, enable features, or raise caps.

8. **Time-Delayed Governance**: All non-emergency changes execute through onchain timelock (48 hours for Standard lane, ~9 days for Slow lane).

9. **Reentrancy Protection**: Critical entrypoints that combine external calls and state transitions use reentrancy protection and follow checks-effects-interactions. Reentrancy risk is treated as a first-class property in testing and review.

10. **Access Control Integrity**: Role-based access control is properly enforced. Deployer roles are revoked after deployment.

---

## System Overview

The protocol consists of:

1. **Core Escrow Contracts** (non-upgradeable):
   - `BaseEscrow`: Abstract base contract with shared escrow logic
   - `EscrowVault`: Multi-token escrow vault (inherits `BaseEscrow`)
   - `EscrowableERC20`: ERC20 token with built-in escrow functionality (inherits `BaseEscrow`)

2. **Resolution Modules** (modular, swappable):
   - `DefaultResolutionModule`: Simple resolver-based resolution
   - `DecentralizedResolutionModule`: Multi-level escalation with senior resolvers (in separate package, can be swapped in via governance once proven)

3. **Resolver Incentive Module** (in separate package with DecentralizedResolutionModule):
   - `ResolverIncentiveModule`: Tracks resolver activity and distributes fees
   - Payment calculation libraries: `PaymentCalculationLibraryV1` (swappable)

4. **Yield Generation Module** (optional):
   - `AaveYieldGenerationModule`: Deposits escrowed funds to Aave for yield generation
   - Protected by exposure caps and pause mechanisms

5. **Governance Infrastructure**:
   - OpenZeppelin `Governor`: Token-based voting
   - OpenZeppelin `TimelockController`: Time-delayed execution (48h delay)
   - Guardian Multisig: Emergency controls (down-only)

**Architecture Principles:**
- Module swaps are time-delayed and affect **new escrows only**
- Module addresses are **snapshotted** at escrow creation
- Governance changes use **queue/activate pattern** for high-impact changes

---

## Deployment Posture (Initial Mainnet)

- **Network**: Base mainnet
- **Core contracts**: Immutable deployments (no proxies)
- **Upgrades**: Performed via governed module swaps affecting **new escrows only**
**Upgradeability posture (initial deployment):**
- The initial mainnet deployment is **immutable** (no proxies for core escrow contracts).
- Protocol evolution is achieved via **governed module swaps** that apply to **new escrows only**.
- All modules are immutable - upgrades are performed by deploying a new version and swapping via Slow lane (~9 days).

**Module Governance**:
- All modules use the same governance pattern: Slow lane (queue + activate, ~9 days)
- Module swaps: Deploy new version → Queue → Wait 7 days → Activate
- Old escrows continue using old module (snapshot preserved)
- New escrows use new module

**Future modules** (not in initial release):
- `DecentralizedResolutionModule` and `ResolverIncentiveModule` are in a separate package and are **not included in the initial mainnet release**.
- When ready, they will be deployed and swapped in via the same Slow lane governance process as other modules.

**Non-upgradeable components (initial deployment):**
- `BaseEscrow`, `EscrowVault`, `EscrowableERC20` are deployed **immutably** (no proxies).
- All modules are deployed as regular contracts (no proxies).

---

## Trust Model

### What Users Must Trust

1. **Token Contracts**: ERC20 tokens behave as specified (balanceOf, transfer, approve work correctly). **Supported tokens must be standard ERC20; fee-on-transfer/rebasing tokens may be unsupported unless explicitly handled.** See "ERC20 Token Support" section below.

2. **Chain Liveness**: Base mainnet remains operational and accessible.

3. **Block Timestamps**: `block.timestamp` is reasonably accurate for auto-release/auto-cancel functionality. TBD — verify tolerance enforcement in code.

4. **External Protocols**: If yield is enabled, Aave protocol functions correctly and does not lose funds.

5. **Governance Process**: Token holders vote honestly and timelock executes proposals correctly.

6. **Resolver Honesty**: Dispute resolution relies on resolver behavior and the protocol's dispute process. Mitigations depend on the active resolution module (e.g., simpler single-resolver vs. later decentralized/escalation module).

### ERC20 Token Support

The protocol assumes standard ERC20 behavior. The following token types may be unsupported or require special handling:

- **Fee-on-transfer tokens**: Tokens that charge a fee on transfer (e.g., PAXG). Balance calculations may be incorrect unless explicitly handled.
- **Rebasing tokens**: Tokens that change total supply (e.g., AMPL). Balance tracking may be incorrect unless explicitly handled.
- **ERC777 hooks**: Tokens with transfer hooks may interact unexpectedly with escrow contracts.
- **Non-standard return values**: Some tokens return `bool` from `transfer()`, others don't. `SafeERC20` handles this, but edge cases may exist.

**Policy**: Supported tokens must be standard ERC20. Fee-on-transfer and rebasing tokens are not explicitly supported unless verified in code. TBD — verify token support policy in contract code.

### What Users Do NOT Need to Trust

1. **Team/Developers**: Cannot modify in-flight escrow rules. Cannot unilaterally change modules for existing escrows.

2. **Governance**: Cannot change rules of existing escrows. Can only affect new escrows via module swaps.

3. **Guardian**: Cannot steal funds, unpause without timelock, or increase risk. Powers are strictly down-only.

4. **Deployer**: All deployer roles are revoked after deployment. Deployer has no ongoing privileges.

5. **Future Code Changes**: Core contracts are non-upgradeable. Module upgrades are time-delayed and transparent.

---

## Funds Custody

**Funds are held by escrow contracts** (`EscrowVault` or `EscrowableERC20`). Resolvers do not have custody of funds; they can only authorize releases through the resolution process. Governance does not have custody; it can only change defaults for new escrows. The fee recipient can only withdraw accumulated protocol fees, not escrowed funds.

This custody model ensures that:
- Escrowed funds remain in escrow contracts until released or refunded
- No single actor (resolver, governance, team) has unilateral access to escrowed funds
- Fee recipient access is limited to accumulated fees only

---

## Assets at Risk

### Escrowed Funds

- **Location**: Held in `EscrowVault` or `EscrowableERC20` contracts
- **Risk**: Incorrect state transitions, reentrancy, rounding errors, unauthorized releases
- **Mitigation**: State machine enforcement, reentrancy guards, payout validation, access control

### Protocol Fee Balances

- **Location**: Accumulated in escrow contracts, withdrawable by fee recipient
- **Risk**: Unauthorized withdrawal, accounting errors
- **Mitigation**: Access control (`onlyRole(ROLE_TIMELOCK)` or fee recipient), fee accounting validation

### Treasury/Reserve Funds

- **Status**: TBD — verify if treasury contract exists
- **Risk**: If exists, unauthorized access or misconfiguration
- **Mitigation**: TBD — verify treasury access controls

### Governance Power / Role Keys

- **Location**: Governor, TimelockController, Guardian multisig keys
- **Risk**: Key compromise, multisig threshold attacks
- **Mitigation**: Hardware wallets, multisig thresholds, time delays, role revocation procedures

### Yield Module Deposits (if enabled)

- **Location**: Deposited to Aave via `AaveYieldGenerationModule`
- **Risk**: Aave protocol failure, accounting errors, cap bypass
- **Mitigation**: Exposure caps, pause mechanism, proper accounting, withdrawal validation

---

## Threat Model

| Threat | Impact | Likelihood | Mitigations |
|--------|--------|------------|-------------|
| **Reentrancy attacks** | High: Fund theft, state corruption | Low | Reentrancy protection on critical entrypoints, `nonReentrant` modifier, checks-effects-interactions pattern |
| **ERC20 token weirdness** | High: Accounting errors, failed transfers | Medium | `SafeERC20` library, explicit balance checks, revert on transfer failure |
| **Signature/approval misuse** | Medium: Unauthorized transfers | Low | TBD — verify if permit functionality exists (removed per docs) |
| **Resolver collusion/bribery** | High: Unfair dispute resolution | Medium | Multi-level escalation (`DecentralizedResolutionModule`), senior resolver registry, incentive alignment, public resolution events |
| **Payout manipulation/rounding** | Medium: Incorrect payouts, remainder loss | Low | Payout validation (`validatePayouts`), proportional yield calculation, rounding tolerance checks, sum validation |
| **Timelock bypass attempts** | High: Unauthorized governance actions | Low | Access control enforcement (`onlyRole(ROLE_TIMELOCK)`), timelock delay enforcement, role revocation checks |
| **Role misconfiguration** | High: Unauthorized access | Low | Deployment scripts verify role revocation, post-deployment checks, `GOVERNANCE_SURFACE_MAP` validation |
| **Guardian key compromise** | High: Protocol pause, cap reduction | Medium | Multisig threshold, hardware wallets, down-only powers (cannot steal funds), unpause requires timelock |
| **Oracle/timestamp dependence** | Medium: Premature/late auto-settlement | Low | `block.timestamp` validation, max duration limits (30 days), tolerance for minor clock skew |
| **External yield integration risks** | High: Fund loss, accounting bugs | Medium | Exposure caps enforced at deposit (`_checkAndAccrueExposure`), pause mechanism (`guardianDisableAave`), proper accounting (`escrowATokenBalance`), withdrawal validation |
| **Cap bypass** | High: Excessive exposure to Aave | Low | Caps checked before deposit, `currentExposure` tracking, revert on cap exceedance |
| **Denial of service via attachments** | Medium: Gas griefing, transaction failures | Low | `maxAttachments` limit (20), gas-efficient storage, batch processing limits (`MAX_AUTOMATION_RANGE = 100`) |
| **Large array DoS** | Medium: Gas limit exhaustion | Low | Array length validation, batch limits, gas-efficient loops |
| **Upgrade/migration mistakes** | High: Logic errors, storage corruption | Low | Core contracts are immutable in the initial deployment. Risk is concentrated in: incorrect module swap execution (queue/activate timing, wrong addresses). All modules use the same swap pattern (Slow lane, ~9 days). Mitigations include timelock lanes, rehearsals on Base Sepolia + fork, and explicit upgrade runbooks. |
| **Module swap errors** | Medium: Broken resolution logic | Low | Module interface validation, time delay (~9 days), testnet rehearsal, snapshot immutability |
| **Dispute timeout bypass** | Medium: Permanently stuck escrows | Low | `maxDisputeDuration` (90 days), `autoCancelDisputedEscrow` function, dispute timestamp tracking |
| **State machine violations** | High: Double-spend, invalid transitions | Low | State machine library (`StateManagementLibrary`), explicit state checks, invariant tests |
| **Snapshot immutability violation** | High: Governance changes existing escrows | Low | Snapshot fields never modified after creation, module getters read from snapshots, no per-escrow setters exist |
| **Fee accounting errors** | Medium: Incorrect fee calculation | Low | Fee calculation in libraries, fee denominator constants, validation tests |
| **Yield distribution errors** | Medium: Incorrect yield allocation | Low | Yield distribution module validation, percentage sum checks (must equal 10000 bps), recipient validation |

---

## Invariants

**Note**: Test names and locations may evolve; this section should be kept in sync with `/test`.

### Lifecycle State Machine Invariants

1. **Valid State Transitions Only**
   - **Enforced**: `StateManagementLibrary.transitionTo*` functions
   - **Tested**: Hardhat unit tests (escrow lifecycle, state transitions), Foundry invariants/fuzz (state machine correctness)
   - **Statement**: Escrow state can only transition along valid paths: NONE → PENDING → {RELEASED, REFUNDED, DISPUTED} → RESOLVED

2. **No Double-Spending**
   - **Enforced**: Balance checks in `resolve()`, `releaseEscrowTransfer()`, `cancelEscrowTransfer()`
   - **Tested**: Foundry invariants/fuzz (balance consistency, double-spend prevention)
   - **Statement**: `remainingBalance` never exceeds `totalDeposited`. Completed escrows (RELEASED/REFUNDED/RESOLVED) have `remainingBalance == 0`.

3. **Workflow ID Consistency**
   - **Enforced**: `nextWorkflowId` increments, `workflowId` matches array index
   - **Tested**: Foundry invariants (workflow ID consistency)
   - **Statement**: `nextWorkflowId == escrowTransfers.length`. Each escrow's `workflowId` matches its array index.

### Snapshot Immutability ("New Escrows Only")

4. **Module Snapshots Never Change**
   - **Enforced**: Snapshot fields (`snapshotResolutionModule`, `snapshotReleaseStrategy`, etc.) are set at creation and never modified
   - **Tested**: Hardhat unit tests (module snapshotting), Foundry invariants (snapshot immutability)
   - **Statement**: Once `EscrowModuleSnapshot` event is emitted, snapshot fields in `EscrowTransfer` struct are immutable.

5. **Module Getters Read from Snapshots**
   - **Enforced**: `getResolutionModule()`, `getReleaseStrategy()` read from `snapshot*` fields, not current defaults
   - **Tested**: Hardhat unit tests (module snapshotting - verify existing escrows use old modules after swap)
   - **Statement**: Existing escrows continue using modules snapshotted at creation, regardless of default module changes.

### No Per-Escrow Admin Overrides

6. **No Per-Escrow Module Setters**
   - **Enforced**: Functions like `setReleaseStrategyForEscrow()`, `setResolutionModuleForEscrow()` were removed (Phase 5)
   - **Tested**: TBD — verify removed functions hard-revert or are absent from ABI
   - **Statement**: No function exists that allows governance to change module selection for a specific escrow after creation.

7. **No Per-Escrow Timeout Overrides**
   - **Enforced**: `autoReleaseTime` and `autoCancelTime` are set at creation and never modified (except via resolution)
   - **Tested**: Hardhat unit tests (state machine, module snapshotting)
   - **Statement**: Timeout values are snapshotted at creation and cannot be changed by governance.

### Caps Enforcement

8. **Caps Enforced at Deposit Time**
   - **Enforced**: `AaveYieldGenerationModule._checkAndAccrueExposure()` reverts if caps exceeded
   - **Tested**: TBD — verify cap enforcement tests exist
   - **Statement**: `currentExposure[token] + amount <= tokenCap[token]` (if cap > 0) and `<= globalCap[token]` (if cap > 0) before deposit.

9. **Exposure Tracking Accuracy**
   - **Enforced**: `currentExposure` incremented on deposit, decremented on withdrawal
   - **Tested**: TBD — verify exposure tracking tests
   - **Statement**: `currentExposure[token]` accurately reflects total deposits minus withdrawals.

### Guardian Down-Only Powers

10. **Guardian Cannot Raise Caps**
    - **Enforced**: `guardianLowerTokenCap()` requires `newCap <= currentCap`
    - **Tested**: Hardhat unit tests (governance lane gating, guardian controls)
    - **Statement**: Guardian can only lower caps, never raise them.

11. **Guardian Cannot Unpause**
    - **Enforced**: `unpause()` requires `ROLE_TIMELOCK`, Guardian does not have this role
    - **Tested**: Hardhat unit tests (access control, emergency policy)
    - **Statement**: Guardian can pause but cannot unpause. Unpause requires timelock (48h delay).

12. **Guardian Cannot Enable Aave**
    - **Enforced**: `setAaveEnabled(true)` requires `ROLE_TIMELOCK`, Guardian can only call `guardianDisableAave()`
    - **Tested**: Hardhat unit tests (guardian controls)
    - **Statement**: Guardian can disable Aave but cannot enable it.

### Governance Time Delays

13. **Slow Lane Queue/Activate Pattern**
    - **Enforced**: `SlowLaneQueueActivate` library, ETA stored onchain, `block.timestamp >= eta` check
    - **Tested**: Hardhat unit tests (governance lane gating, slow lane queue/activate)
    - **Statement**: Slow lane changes require queue (48h delay) + 7 day wait + activate (48h delay) = ~9 days total.

14. **Standard Lane Timelock Delay**
    - **Enforced**: All Standard lane functions require `ROLE_TIMELOCK`, TimelockController enforces 48h delay
    - **Tested**: Hardhat unit tests (timelock integration, governance lane gating)
    - **Statement**: Standard lane changes execute through TimelockController with 48 hour minimum delay.

15. **Emergency Lane Immediate Execution**
    - **Enforced**: Emergency functions use `onlyRole(ROLE_GUARDIAN)`, no timelock delay
    - **Tested**: Hardhat unit tests (emergency policy, access control)
    - **Statement**: Guardian functions execute immediately (0h delay) but are down-only.

---

## Governance & Admin Controls

### Roles

1. **Governor** (OpenZeppelin Governor)
   - **Powers**: Propose and vote on governance proposals
   - **Limits**: Cannot execute directly (proposals go through Timelock)
   - **Key Management**: Token holder voting, multisig recommended for proposal submission

2. **TimelockController**
   - **Powers**: Execute Standard lane (48h delay) and Slow lane (~9 days) changes
   - **Roles**: Has `ROLE_TIMELOCK` on all governed contracts
   - **Limits**: Cannot execute Emergency lane functions (does not have `ROLE_GUARDIAN`)
   - **Configuration**: `PROPOSER_ROLE` → Governor, `EXECUTOR_ROLE` → `address(0)` (open execution), `CANCELLER_ROLE` → Governor only

3. **Guardian Multisig**
   - **Powers**: Emergency lane (immediate, down-only)
     - `pause()` - Pause protocol
     - `guardianDisableAave()` - Disable Aave deposits
     - `guardianLowerTokenCap()` - Lower token exposure cap
     - `guardianLowerGlobalCap()` - Lower global exposure cap
   - **Limits**: Cannot unpause, enable Aave, raise caps, change modules, change fees, redirect funds
   - **Key Management**: Multisig (threshold TBD — verify in deployment config), hardware wallets recommended

4. **Fee Recipient**
   - **Powers**: Withdraw accumulated protocol fees
   - **Limits**: No governance authority, cannot modify escrow rules
   - **Access Control**: `onlyRole(ROLE_TIMELOCK)` or dedicated fee recipient role (TBD — verify)

5. **Deployer**
   - **Powers**: None after deployment
   - **Post-Deployment**: All roles revoked, ownership transferred to Timelock

### Governance Lanes

1. **Standard Lane** (48h delay)
   - **Executor**: TimelockController
   - **Scope**: Bounded parameter changes (timeouts, max attachments, caps within bounds, yield distribution defaults)
   - **Examples**: `setDefaultAutoCancelTime()`, `setMaxAttachments()`, `setTokenCap()`

2. **Slow Lane** (~9 days: 48h queue + 7d wait + 48h activate)
   - **Executor**: TimelockController
   - **Scope**: High-impact changes (module swaps, fee changes, escalation config)
   - **Examples**: `queueDefaultResolutionModule()` / `activateDefaultResolutionModule()`, `queueEscrowFee()` / `activateEscrowFee()`

3. **Emergency Lane** (0h delay)
   - **Executor**: Guardian Multisig
   - **Scope**: Risk reduction only (pause, disable yield, lower caps)
   - **Examples**: `pause()`, `guardianDisableAave()`, `guardianLowerTokenCap()`

### What Can Be Changed

- Default modules (affects new escrows only)
- Default timeouts (affects new escrows only)
- Max attachments (global limit)
- Fee rates and fee recipient (Slow lane)
- Exposure caps (Standard lane for set, Emergency lane for lower)
- Senior resolver registry (affects new disputes only)
- Escalation configuration (Slow lane)

### What Cannot Be Changed

- In-flight escrow rules (modules, timeouts, resolver)
- Core escrow contract logic (non-upgradeable in initial deployment)
- Snapshot fields in existing escrows
- Guardian's emergency powers cannot be used to increase risk (down-only)
- Any governance wiring changes (if supported) must be Slow-lane governed; otherwise immutable (TBD — verify surfaces in code)

### Explicit Guarantee

**The team, governance, and any admin actor cannot unilaterally change the rules of an existing escrow.** Module swaps, timeout changes, and other governance actions affect only escrows created after the change. This is enforced by:
- Snapshot immutability (snapshot fields never modified)
- No per-escrow setters (removed in Phase 5)
- Access control (no role can modify snapshot fields)

---

## Known Limitations

The protocol has the following known limitations:

1. **Block Timestamp Dependence**: Auto-release and auto-cancel functionality relies on `block.timestamp`. While generally accurate, miners/validators can manipulate timestamps within a small window (~15 minutes). This is a known limitation of onchain time-based automation.

2. **Dispute Resolution is a Social Process**: While dispute resolution is executed onchain, the decision-making process (resolver judgment) is inherently social. The protocol provides technical guarantees (access control, time delays, escalation) but cannot eliminate the need for human judgment in disputes.

3. **Governance Can Change Defaults for New Escrows**: By design, governance can change default modules, timeouts, and other parameters. These changes affect only escrows created after the change (snapshot immutability), but users should be aware that protocol defaults may evolve.

4. **External Protocol Dependencies**: If yield generation is enabled, the protocol depends on Aave functioning correctly. Aave protocol failures or exploits could affect yield generation, though caps and pause mechanisms limit exposure.

5. **Token Support Limitations**: Non-standard ERC20 tokens (fee-on-transfer, rebasing) may not be fully supported. See "ERC20 Token Support" section.

6. **Gas Costs**: Complex operations (dispute resolution with multiple payouts, large attachment arrays) may have high gas costs. Users should be aware of gas implications.

These limitations are documented to provide transparency. They do not represent vulnerabilities but rather inherent constraints of the protocol design.

---

## Operational Security

### Key Management Expectations

1. **Governor**: Token-based voting, multisig recommended for proposal submission
2. **TimelockController**: Self-administered (`TIMELOCK_ADMIN_ROLE` → TimelockController itself)
3. **Guardian Multisig**: 
   - Multisig threshold: TBD — verify in deployment config (recommend 3-of-5 or higher)
   - Hardware wallets for signers
   - Geographic distribution of signers
   - Key rotation procedures (TBD — document in runbook)

4. **Fee Recipient**: Multisig or timelock-controlled address

### Deployment Ceremony Checklist

1. **Pre-Deployment**
   - [ ] All contracts audited (TBD — verify audit status)
   - [ ] Testnet deployment successful (Base Sepolia)
   - [ ] Fork simulation successful
   - [ ] All tests passing
   - [ ] Slither analysis clean (or triaged)

2. **Deployment**
   - [ ] Deploy core contracts (non-upgradeable)
   - [ ] Deploy modules
   - [ ] Deploy governance (GovToken, TimelockController, Governor)
   - [ ] Wire roles (grant `ROLE_TIMELOCK` to Timelock, `ROLE_GUARDIAN` to Guardian)
   - [ ] Revoke deployer roles
   - [ ] Transfer ownership to Timelock
   - [ ] Verify all roles correct (post-deployment checks)

3. **Post-Deployment**
   - [ ] Verify contracts on Basescan
   - [ ] Verify role assignments
   - [ ] Test emergency pause (then unpause via timelock)
   - [ ] Document deployed addresses
   - [ ] Publish parameter snapshot

### Monitoring/Alerting Ideas

**Events to Watch:**
- `EscrowStateChanged` → Monitor for unexpected state transitions
- `DisputeOpened` → Track dispute rate
- `EscrowResolved` → Verify resolution outcomes
- `EscrowFeeUpdated` → Alert on fee changes
- `EscrowFeeAddressUpdated` → Alert on fee recipient changes
- `DefaultResolutionModuleActivated` → Alert on module swaps
- `TokenCapSet` / `TokenCapLowered` → Monitor cap changes
- `AaveWithdrawalFailedEvent` → Alert on Aave withdrawal failures
- `DisputeAutoCancelled` → Monitor stuck disputes
- `Paused` / `Unpaused` → Alert on pause state changes

**Metrics to Track:**
- Total escrowed value
- Number of active escrows
- Dispute rate
- Average dispute resolution time
- Aave exposure vs. caps
- Fee accumulation rate

**Alert Thresholds:**
- Large escrow creation (> threshold TBD)
- Dispute rate spike
- Cap near limit (> 80% of cap)
- Aave withdrawal failure
- Unexpected pause/unpause
- Module swap activation

---

## Incident Response Runbook Summary

### Suspected Exploit

1. **Immediate Actions**:
   - Guardian pauses protocol (`pause()` on all escrow contracts)
   - Guardian disables Aave (`guardianDisableAave()`) if yield enabled
   - Guardian lowers caps to 0 if Aave exposure exists
   - Assess scope and impact

2. **Communication**:
   - Internal team notification
   - Public disclosure (if funds at risk): TBD — verify disclosure policy
   - Coordinate with security researchers if applicable

3. **Investigation**:
   - Review transaction history
   - Identify affected escrows
   - Determine root cause
   - Assess total impact

### Recovery Steps

1. **Unpause Protocol**:
   - Requires Timelock proposal (48h delay)
   - Governor proposes `unpause()` call
   - After 48h delay, Timelock executes
   - Verify protocol functioning correctly

2. **Re-enable Features** (if needed):
   - Re-enable Aave: Timelock proposal (48h delay)
   - Raise caps: Timelock proposal (48h delay)
   - Module swaps: Slow lane (~9 days)

3. **Post-Incident**:
   - Document incident and resolution
   - Update security model if needed
   - Consider additional mitigations
   - Communicate resolution to users

### Emergency Contacts

- **Guardian Multisig**: TBD — verify contact procedure
- **Security Team**: TBD — verify contact information
- **Legal/Compliance**: TBD — verify if applicable

---

## Appendix

### Key Events

**Event Categories** (verify exact names in contract code):

1. **Escrow Creation + Funding**: Events emitted when escrows are created and funded
2. **Escrow State Transitions**: Events for release, refund, dispute, and resolution state changes
3. **Dispute Lifecycle + Escalation**: Events for dispute opening, escalation (if supported), and resolution
4. **Governance Changes**: 
   - Queue/activate events for slow lane changes
   - Parameter update events for standard lane changes
5. **External Integration Actions**: 
   - Yield deposit/withdraw events (if yield enabled)
   - Cap changes and disable switches

**Note**: Verify exact event signatures in contract code. Event names and parameters may differ from this conceptual list.

### Related Documentation

- **Governance Model**: [`docs/governance.md`](./governance.md)
- **Governance Surface Map**: [`docs/GOVERNANCE_SURFACE_MAP.md`](./GOVERNANCE_SURFACE_MAP.md)
- **Emergency Policy**: [`docs/EMERGENCY_POLICY.md`](./EMERGENCY_POLICY.md)
- **Governance Process**: [`docs/GOVERNANCE_PROCESS.md`](./GOVERNANCE_PROCESS.md) (TBD — verify exists)
- **Operational Runbooks**: `governance/runbooks/` (TBD — verify contents)
- **Audit Documentation**: `docs/AUDIT.md` (TBD — verify exists)
- **Technical Overview**: [`docs/TECHNICAL_OVERVIEW.md`](./TECHNICAL_OVERVIEW.md)
- **Module Map**: [`docs/MODULE_MAP.md`](./MODULE_MAP.md)

### Security Contact

**TBD** — Verify security contact information and disclosure policy in `SECURITY.md`.

---

**Document Status**: This is a living document. Update when:
- New threats are identified
- New mitigations are implemented
- Governance structure changes
- External dependencies change
- Audit findings are incorporated

