# UX and Wallet Integration Plan: Time-Based Escrow Legibility

## 1. Executive Summary (Revised)
This proposal focuses on making time-based escrows **legible, discoverable, and safe** for wallets and their users. 

While the protocol enforces deterministic rules on-chain, wallets currently lack the semantic signals needed to explain *what* is happening, *why* it happened, and *what actions* are available to the user. The goal is to expose the protocol’s time-based intent so wallets can reliably surface which escrows matter, which deadlines are approaching, and when user intervention is possible.

By introducing richer events, explicit “actionable” states, and a consolidated timeline view, we enable wallets to provide clear notifications and safe call-to-action buttons without re-implementing protocol logic.

## 2. Key UX Enhancements

### A. Execution Source Attribution
Wallets need to distinguish between automated protocol behavior and human intervention.
*   **Addition:** `ExecutionSource { USER, KEEPER, GOVERNANCE }` enum.
*   **Impact:** Reduces user panic. Notifications can say "Automatically released by protocol" vs "Manually released by Buyer."

### B. Tiered Urgency Levels
A simple boolean is insufficient for high-stakes dispute windows.
*   **Addition:** `UrgencyLevel { NONE, LOW, MEDIUM, HIGH, CRITICAL }`.
*   **Mapping:**
    *   `LOW`: > 48h remaining.
    *   `MEDIUM`: < 48h (Rabby/Safe might show a yellow badge).
    *   `HIGH`: < 24h (Push notification territory).
    *   `CRITICAL`: < 1h (Banner/High-priority alert).

### C. Explicit Actionability
Wallets should not derive "can I press this button?" logic from state enums.
*   **Addition:** `bool userCanExecute` flag in the view struct.
*   **Impact:** If `true`, the wallet surfaces the primary action button immediately.

### D. Role-Aware Discovery
Wallets often need to filter "My Incoming Payments" vs "My Active Disputes."
*   **Addition:** `UserRole { BUYER, SELLER, RESOLVER }` and role-based filtering in the View contract.

---

## 3. Technical Specification

### New Types (`EscrowTypes.sol`)
```solidity
enum ExecutionSource { USER, KEEPER, GOVERNANCE }

enum UrgencyLevel { NONE, LOW, MEDIUM, HIGH, CRITICAL }

enum ActionableStatus {
    NONE,
    AWAITING_CONDITION, // Pending, time/condition not yet met
    TIME_CONDITION_MET, // Ready for trigger (automateTimedActions)
    DISPUTED_WAITING,   // In dispute, awaiting resolver
    APPEAL_WINDOW,      // Resolved, awaiting appeal expiry
    APPEAL_READY,       // Appeal window met, call executePending()
    FINALIZED           // Closed
}

struct EscrowTimeline {
    uint64 createdAt;
    uint64 nextDeadline;
    uint64 finalDeadline; // Irreversible settlement timestamp
    ActionableStatus status;
    UrgencyLevel urgency;
    bool userCanExecute;
}
```

### New Events (`IEscrowEvents.sol` / `BaseEscrow.sol`)
```solidity
event TimedActionTriggered(
    uint256 indexed workflowId, 
    uint8 actionType, 
    ExecutionSource source, 
    address indexed executor
);
```

---

## 4. Development Plan

### Phase 1: Core Type Integration
1.  Add new enums and the `EscrowTimeline` struct to `contracts/types/EscrowTypes.sol`.
2.  Add `TimedActionTriggered` event to `BaseEscrow.sol`.

### Phase 2: Minimal BaseEscrow Updates
1.  Update `automateTimedActions` to emit `TimedActionTriggered`.
2.  Pass `ExecutionSource.KEEPER` or `USER` based on `msg.sender` (minimal bytecode impact).

### Phase 3: Advanced View & Keeper Logic (`EscrowViewContract.sol`)

1.  **Status Derivation:** Implement the logic to map internal states + timestamps to `ActionableStatus`.

2.  **Timeline Aggregator:** Implement `getEscrowTimeline(uint256 workflowId)` to calculate deadlines and urgency tiers.

3.  **Filtered Discovery:** Implement `getWorkflowsByRole(address user, UserRole role)`.

4.  **Gelato Pre-check:** Add `canAutomate(uint256 workflowId)` returning `(bool ok, uint8 actionType, bool isRelease)` to serve as a reliable checker for Gelato tasks.



### Phase 4: Keeper Infrastructure

1.  **Gelato Adapter:** Create a `GelatoKeeperAdapter.sol` contract that implements the `checker()` pattern.

2.  **Batch Processing:** Implement a strategy to paginate and find workable `workflowIds` efficiently.



## 5. Gelato-First Automation Refinement

The `automateTimedActions` function will use a "deterministic tail" approach:

1.  Compute authority source (USER/KEEPER/GOVERNANCE).

2.  Handle settlement specific logic (e.g., `actionType 3` clears pending state).

3.  Execute final transfer (Release/Refund) based on `isRelease`.

4.  Emit `TimedActionTriggered` event containing the source attribution.
