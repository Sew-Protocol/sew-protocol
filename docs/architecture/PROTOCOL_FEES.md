# Protocol Fees

**Last Updated:** 2026-01-28 (Added Fee Snapshot Immutability)

This section defines the fees that may be collected by the protocol, how they are calculated, and how they are governed. All protocol fees are **explicit, bounded, on-chain, governance-controlled, and immutable per-escrow**.

## Design Principles

* **Optionality:** The protocol can operate with all fees set to zero.
* **Non-interference:** Fees never affect escrow principal.
* **Immutability:** Protocol fees are snapshotted per-escrow at creation - fees cannot change during an escrow's lifetime, ensuring predictable economics for users.
* **Modularity:** Fee logic is isolated in dedicated modules and can be enabled, disabled, or upgraded via governance.
* **Transparency:** All fee parameters, accruals, and withdrawals are observable on-chain via events.
* **Governance control:** Any change to fee parameters is subject to DAO governance and timelock, but only affects new escrows (existing escrows retain their snapshotted fees).

---

## 1. Yield Protocol Fee (Optional)

When enabled, the protocol may collect a **Protocol Fee on yield generated from escrowed funds**.

* **Fee base:** Yield only (never escrow principal)
* **Applicability:** Only when a yield generation module is explicitly enabled
* **Configurability:** Set in basis points (`yieldProtocolFeeBps`)
* **Fallback:** If yield generation fails or is disabled, escrow execution proceeds normally with no fee

**Indicative parameters**

* Default at launch: 3000 bps (30%)
* Typical operating range: 0-30% of generated yield
* Maximum allowable value: 3000 bps (30%) - governance-defined hard cap

**Notes**

* Yield generation is best-effort and non-guaranteed.
* Users are never required to opt into yield to use the escrow protocol.
* Protocol fee is deducted from yield before distribution to recipients.

**Implementation**

The protocol fee is calculated and collected in `YieldOps.handleYield()`:

```solidity
uint256 protocolFeeAmount = (yieldAmount * yieldProtocolFeeBps) / 10000;
uint256 yieldToDistribute = yieldAmount - protocolFeeAmount;
```

The protocol fee is transferred to `escrowFeeAddress` before the remaining yield is distributed to recipients via the yield distribution module.

---

## 2. Appeal Protocol Fee (Planned / Optional)

In dispute escalation scenarios, appeals may require the posting of an appeal bond. A **Protocol Appeal Fee** may be introduced to cover the operational cost of escalation and dispute infrastructure.

* **Status:** Active but set to 0% at launch
* **Nature:** Non-refundable appeal processing fee
* **Fee base:** A percentage of the appeal bond
* **Configurability:** Set in basis points (`appealBondProtocolFeeBps`)
* **Scope:** Applied only when an appeal is initiated

**Indicative parameters**

* Default at launch: 0 bps (0%)
* Expected range: 0-30% of the appeal bond
* Maximum allowable value: 3000 bps (30%) - governance-defined hard cap

**Notes**

* When inactive (set to 0%), appeal bonds are refunded or distributed in full according to dispute outcomes.
* Activation requires an explicit governance proposal and timelock.
* Protocol fee is deducted from the appeal bond before the bond is recorded in the incentive module.

**Implementation**

The protocol fee is calculated and collected in `BaseEscrow.escalateDispute()` when an appeal bond is posted:

```solidity
uint256 protocolFeeAmount = (bondAmount * appealBondProtocolFeeBps) / 10000;
uint256 bondToRecord = bondAmount - protocolFeeAmount;
```

The protocol fee is transferred to `escrowFeeAddress` before the remaining bond is recorded in the incentive module.

---

## 3. Governance and Controls

All protocol fees are:

* Controlled by DAO governance
* Subject to timelock delays
* Bounded by immutable maximums
* Upgradeable only via approved module changes

The DAO may:

* Enable or disable individual fees
* Adjust fee parameters within predefined limits (0-3000 bps)
* Redirect fee proceeds according to governance decisions

### Slow Lane Governance

All protocol fee changes use the **Slow Lane** governance pattern:

1. **Queue Proposal:** Governance proposes a fee change via `queueYieldProtocolFeeBps()` or `queueAppealBondProtocolFeeBps()`
2. **Voting Period:** 3-7 days for community voting
3. **Queue Execution:** After successful vote, change is queued with 7-day delay
4. **Activation Proposal:** After 7-day wait, governance proposes activation via `activateYieldProtocolFeeBps()` or `activateAppealBondProtocolFeeBps()`
5. **Activation Execution:** After successful vote and 48-hour timelock, change is activated

**Total Timeline:** ~9-14 days from proposal to activation

### Functions

**Yield Protocol Fee:**
- `queueYieldProtocolFeeBps(uint256 feeBps)` - Queue a new yield protocol fee (0-3000 bps)
- `activateYieldProtocolFeeBps()` - Activate the queued yield protocol fee
- `getPendingYieldProtocolFeeBps()` - View pending fee change information
- `yieldProtocolFeeBps` - Current yield protocol fee in basis points

**Appeal Bond Protocol Fee:**
- `queueAppealBondProtocolFeeBps(uint256 feeBps)` - Queue a new appeal bond protocol fee (0-3000 bps)
- `activateAppealBondProtocolFeeBps()` - Activate the queued appeal bond protocol fee
- `getPendingAppealBondProtocolFeeBps()` - View pending fee change information
- `appealBondProtocolFeeBps` - Current appeal bond protocol fee in basis points

---

## 4. Fee Immutability Per-Escrow

**Critical Feature**: Protocol fees are **snapshotted per-escrow at creation time**, ensuring fees cannot change during an escrow's lifetime.

### Implementation

When an escrow is created, the current global protocol fee values are stored in the `ModuleSnapshot` struct:

```solidity
struct ModuleSnapshot {
    address resolutionModule;
    address releaseStrategy;
    address yieldGenerationModule;
    address yieldDistributionModule;
    uint256 yieldProtocolFeeBps;      // Snapshotted at creation
    uint256 appealBondProtocolFeeBps; // Snapshotted at creation
}
```

### Behavior

* **At Escrow Creation**: Current global protocol fees are snapshotted and stored with the escrow
* **During Escrow Lifetime**: The snapshotted fees are used for all fee calculations, regardless of global fee changes
* **Fee Disclosure**: `EscrowFeeSnapshot` event is emitted at creation with complete fee breakdown
* **Governance Changes**: Changes to global protocol fees only affect new escrows created after the change

### Example

```
Day 1: User creates escrow with yield enabled
       - Global yieldProtocolFeeBps = 30%
       - Snapshot stores: yieldProtocolFeeBps = 30%
       - Escrow created with 30% yield fee (locked)
       
Day 30: Governance increases global yieldProtocolFeeBps to 50%
        - User's escrow still active
        - User's escrow still uses 30% (snapshotted value)
        - New escrows created after Day 30 use 50%
        
Day 60: Escrow releases
        - User pays 30% on yield (snapshotted fee, not current global fee)
```

### Benefits

* **Predictable Economics**: Users know fees upfront and fees cannot change unexpectedly
* **Fair Treatment**: All escrows created at the same time have the same fees, regardless of governance changes
* **Consistent with Module Snapshots**: Follows the same immutability pattern as module snapshots

## 5. Fee Transparency

The protocol emits on-chain events for:

* Fee parameter changes (`YieldProtocolFeeBpsUpdated`, `AppealBondProtocolFeeBpsUpdated`)
* Fee snapshots at creation (`EscrowFeeSnapshot` - includes escrow fee, yield protocol fee, appeal bond protocol fee)
* Fee accrual (`YieldProtocolFeeCollected`, `AppealBondProtocolFeeCollected`)
* Fee withdrawal (via existing `FeesWithdrawn` event)

This ensures that all protocol fees are independently verifiable by users, auditors, and exchanges.

---

## Summary

| Fee Type            | Applies To   | Default at Launch        | Governance Controlled | Maximum | Immutability |
| ------------------- | ------------ | ------------------------ | --------------------- | ------- | ------------ |
| Yield Protocol Fee  | Yield only   | 3000 bps (30%)           | Yes (Slow Lane)       | 3000 bps | **Snapshotted per-escrow** |
| Appeal Protocol Fee | Appeal bonds | 0 bps (0%)               | Yes (Slow Lane)       | 3000 bps | **Snapshotted per-escrow** |

**Key Points:**

* The protocol is designed to remain fully functional with all protocol fees set to zero.
* **Protocol fees are snapshotted per-escrow at creation** - fees cannot change during an escrow's lifetime.
* Governance can change global fee parameters, but only new escrows are affected (existing escrows retain their snapshotted fees).
* Fee disclosure event (`EscrowFeeSnapshot`) is emitted at creation for transparency.

---

## Implementation Details

### Contract Locations

- **BaseEscrow.sol:** Protocol fee storage, governance functions, and appeal bond fee collection
- **YieldOps.sol:** Yield protocol fee calculation and collection
- **EscrowVault.sol / EscrowableERC20.sol:** Protocol fee initialization (3000 bps and 0 bps respectively)

### Constants

- `MAX_PROTOCOL_FEE_BPS = 3000` - Maximum allowed protocol fee (30%)
- `ESCROW_FEE_DENOMINATOR = 10000` - Basis points denominator (100%)

### Events

- `EscrowFeeSnapshot(uint256 indexed workflowId, uint256 escrowFee, uint256 yieldProtocolFeeBps, uint256 appealBondProtocolFeeBps)` - Emitted at escrow creation with complete fee breakdown
- `YieldProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps)` - Emitted when global yield protocol fee is updated
- `AppealBondProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps)` - Emitted when global appeal bond protocol fee is updated
- `YieldProtocolFeeCollected(uint256 indexed escrowId, address indexed token, uint256 yieldAmount, uint256 protocolFeeAmount)` - Emitted when yield protocol fee is collected (uses snapshotted fee)
- `AppealBondProtocolFeeCollected(uint256 indexed escrowId, address indexed token, uint256 bondAmount, uint256 protocolFeeAmount)` - Emitted when appeal bond protocol fee is collected (uses snapshotted fee)
