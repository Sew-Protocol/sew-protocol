# DR v2 Implementation Summary

**Date:** 2026-01-13  
**Status:** ✅ Core Implementation Complete, Tests Pending  
**Test Coverage:** 107 tests passing (v1 tests, v2 tests not yet created)

## Overview

Implemented DR v2 (Decentralise Incentives) phase of the staged dispute resolution rollout. This phase adds **appeal bonds** and **escalation cost curves** while keeping resolvers risk-free (no staking/slashing yet).

---

## Key Principles

1. **Users post bonds to escalate** (not resolvers)
2. **Refund if appeal succeeds** (decision changes)
3. **Pay to resolvers if appeal fails** (decision upheld)
4. **Increasing costs discourage frivolous appeals** (quadratic curve recommended)
5. **No resolver capital at risk** (DR v3 feature)

---

## What's New in DR v2

### 1. Appeal Bond System

**User Flow:**

1. User wants to escalate dispute from round k to k+1
2. System calculates required bond via `getRequiredAppealBond()`
3. Escrow contract collects bond from user
4. Escrow calls `recordAppealBond()` to track deposit
5. Next round resolver makes decision
6. System calls `distributeAppealBond()`:
   - If decision differs from prior round → **refund bond to user**
   - If decision same as prior round → **pay bond to prior round's resolvers**

**Bond Tracking (per dispute/round):**

```solidity
struct AppealBondRecord {
  address depositor; // Who posted the bond
  uint256 amount; // Bond amount
  address token; // Token address (address(0) = ETH)
  uint256 depositedAt; // Timestamp
  bool distributed; // Whether refunded/paid
  bool refunded; // True = refunded, False = paid to resolvers
}
```

### 2. Escalation Cost Curves

**Configuration:**

```solidity
struct EscalationCostConfig {
  CostCurveType curveType; // LINEAR, QUADRATIC, GEOMETRIC
  uint256 baseCost; // Base cost (e.g., 100 tokens)
  uint256 stepSize; // Step increment
  uint256 multiplier; // For geometric (scaled by 1e18)
  address bondToken; // Token for bonds (address(0) = ETH)
  bool enabled; // Master switch
}
```

**Cost Formulas:**

- **Linear:** `bond(k) = baseCost + stepSize × k`
- **Quadratic (recommended):** `bond(k) = baseCost + stepSize × k²`
- **Geometric:** `bond(k) = baseCost × (multiplier/1e18)^k`

**Example (Quadratic with base=100, step=50):**

- Round 0→1: 100 + 50×0² = **100 tokens**
- Round 1→2: 100 + 50×1² = **150 tokens**
- Round 2→3: 100 + 50×2² = **300 tokens** (if round 3 existed)

### 3. Observability Metrics

**Tracked Metrics:**

- `totalBondsPosted` - Sum of all bonds deposited
- `totalBondsRefunded` - Sum of bonds returned to depositors (appeals succeeded)
- `totalBondsPaidToResolvers` - Sum of bonds paid to resolvers (appeals failed)
- `totalBondsForfeited` - Sum of bonds confiscated (escalator didn't follow through)
- `escalationDepthHistogram[round]` - Count of escalations to each round

**View Functions:**

```solidity
function getV2Metrics()
  external
  view
  returns (
    uint256 bondsPosted,
    uint256 bondsRefunded,
    uint256 bondsPaidToResolvers,
    uint256 bondsForfeited
  );

function getEscalationDepthHistogram()
  external
  view
  returns (uint256 round0, uint256 round1, uint256 round2);
```

### 4. Anti-Griefing Measures

**Minimum Escrow Value:**

- Governance can set `minEscrowValueForEscalation`
- Prevents escalation of low-value disputes beyond threshold
- Example: Require $1000 minimum to escalate to round 2 (Kleros)

**Increasing Delays** (already in v1, now meaningful with bonds):

- `resolveDeadlines[k]` - Time for resolver to decide
- `appealWindows[k]` - Time window to post appeal bond
- Can increase with depth to throttle spam

**Bond Forfeiture:**

```solidity
function forfeitAppealBond(uint256 workflowId, uint8 round, string memory reason)
```

- Escrow can forfeit bond if escalator doesn't follow through
- Example: Posted bond but didn't submit required evidence
- Bond remains in contract as protocol revenue

---

## Files Created

### Contracts

- `/contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol` (370 lines)
  - Extends `ResolverIncentiveModuleV1`
  - Adds `recordAppealBond()`, `distributeAppealBond()`, `forfeitAppealBond()`
  - Implements bond refund and payout logic
  - Tracks observability metrics
  - Can receive ETH for bond deposits

---

## Files Modified

### Core Contracts

**`DecentralizedResolverStructs.sol`:**

- Extended `DisputeMetadata` with bond tracking arrays:
  ```solidity
  address[3] bondDepositorAtRound;
  uint256[3] bondAmountAtRound;
  address[3] bondTokenAtRound;
  bool[3] bondRefundedAtRound;
  ```
- Added `bondToken` field to `EscalationCostConfig`

**`DecentralizedResolutionModule.sol`:**

- Added DR v2 storage:
  - `escalationCostConfig` - cost curve configuration
  - `minEscrowValueForEscalation` - anti-griefing threshold
- Implemented `getRequiredAppealBond()`:
  - Calculates bond using `EscalationCostLibrary`
  - Returns amount and token based on configuration
- Added governance functions:
  - `queueEscalationCostConfig()` / `activateEscalationCostConfig()` (slow lane)
  - `setMinEscrowValueForEscalation()` (slow lane)
- Added DR v2 events:
  - `EscalationCostConfigQueued`, `EscalationCostConfigActivated`
  - `AppealBondRequired`, `MinEscrowValueUpdated`

---

## Architecture: Stable Core + Swappable V2

**Module Swap (v1 → v2):**

```
Before: DecentralizedResolutionModule + IncentiveModuleV1
After:  DecentralizedResolutionModule + IncentiveModuleV2 (swap only)
```

**What Changes:**

- `IncentiveModuleV1` → `IncentiveModuleV2`
- New: Appeal bond tracking and distribution
- New: V2 observability metrics

**What Stays:**

- `DecentralizedResolutionModule` unchanged (stable core)
- Round-based dispute flow
- EMA-based resolver scoring
- Timeout handling
- Phase gate metrics

**Governance Flow:**

1. Deploy `ResolverIncentiveModuleV2` (proxy)
2. Configure escalation cost curve via `queueEscalationCostConfig()` + wait + `activateEscalationCostConfig()`
3. Call `DecentralizedResolutionModule.setIncentiveModule(addressV2)` via ROLE_TIMELOCK
4. Existing disputes continue with V1 logic
5. New disputes use V2 with appeal bonds

---

## Integration Flow (Escrow → Resolution → Incentive)

### 1. User Escalates Dispute

**Escrow Contract:**

```solidity
// Get required bond
(uint256 bondAmount, address bondToken) =
    resolutionModule.getRequiredAppealBond(workflowId, currentRound, escrowData);

// Collect bond from user
if (bondToken == address(0)) {
    // ETH
    require(msg.value >= bondAmount, "Insufficient bond");
} else {
    // ERC20
    IERC20(bondToken).transferFrom(msg.sender, address(this), bondAmount);
}

// Record bond in incentive module
incentiveModuleV2.recordAppealBond(
    workflowId,
    msg.sender,  // depositor
    bondAmount,
    bondToken,
    nextRound
);

// Execute escalation
resolutionModule.executeEscalation(workflowId, "");
```

### 2. Next Round Resolver Decides

**Escrow Contract (after resolution):**

```solidity
// Get decisions from both rounds
bool outcomeFlipped = (
    decisionAtRound[currentRound] != decisionAtRound[priorRound]
);

// Distribute bond
incentiveModuleV2.distributeAppealBond(
    workflowId,
    priorRound,
    outcomeFlipped
);
```

**IncentiveModuleV2 (internal):**

- If `outcomeFlipped = true`: Refund bond to depositor
- If `outcomeFlipped = false`: Pay bond to resolvers from `priorRound`

---

## Security Considerations

### Risks Introduced

1. **Bond Custody Risk:**
   - IncentiveModuleV2 holds user bonds
   - Mitigation: UUPS upgradeable with timelock, pull pattern for claims

2. **Bond Calculation Manipulation:**
   - Incorrect cost curve could price out legitimate appeals
   - Mitigation: Slow lane governance, phase gates before v2 activation

3. **Resolver Collusion:**
   - Resolvers at round k might collude to uphold wrong decisions to earn bonds
   - Mitigation: Random selection, EMA scoring penalizes bad actors, Kleros backstop

4. **Griefing via Small Bonds:**
   - If bonds too low, spam appeals possible
   - Mitigation: Quadratic curve, `minEscrowValueForEscalation`, bond forfeiture

### Risks Mitigated

1. **Frivolous Appeals:**
   - Before v2: Anyone could escalate for free (just escalation fee)
   - After v2: Escalator loses bond if appeal fails
   - Result: Appeals become economically rational decisions

2. **Appeal Spam:**
   - Before v2: Constant escalation fee, flat cost
   - After v2: Quadratic growth (100 → 150 → 300...)
   - Result: Deep escalations become prohibitively expensive

3. **Resolver Revenue Uncertainty:**
   - Before v2: Resolvers only earn escrow fees (fixed pool)
   - After v2: Resolvers also earn failed appeal bonds
   - Result: Incentive to make correct decisions (earn bonds)

---

## Economics Example

**Scenario:**

- Dispute value: $10,000
- Escalation cost config: Quadratic, base=100 USDC, step=50 USDC
- Escrow fee: 2% = $200 USDC (split among resolvers)

**Round 0 (Standard Resolver):**

- Resolver1 decides: Release to buyer
- Seller disagrees, wants to escalate

**Escalation 0→1:**

- Required bond: 100 + 50×0² = **100 USDC**
- Seller posts 100 USDC bond
- Escalates to senior resolver

**Round 1 (Senior Resolver):**

- SeniorResolver1 decides: Cancel (return to seller)
- Decision **changed** from round 0
- **Outcome:** Seller's bond (100 USDC) **refunded** (appeal succeeded)

**Alternative Scenario:**

- Senior resolver also decides: Release to buyer
- Decision **unchanged** from round 0
- **Outcome:** Seller's bond (100 USDC) **paid to Resolver1** (appeal failed)

**Resolver1 Total Earnings:**

- Base case (no escalation): ~$100 USDC (50% of escrow fee)
- Failed appeal case: ~$100 + $100 = **$200 USDC** (escrow fee + bond)

**Key Insight:** Resolvers earn MORE when they make decisions that are upheld on appeal, creating incentive alignment.

---

## Governance Parameters (Recommended Defaults)

### Escalation Cost Curve (Quadratic)

```solidity
EscalationCostConfig({
    curveType: CostCurveType.QUADRATIC,
    baseCost: 100e18,        // 100 tokens (e.g., USDC with 18 decimals)
    stepSize: 50e18,         // 50 tokens per k²
    multiplier: 0,           // Unused for quadratic
    bondToken: USDC_ADDRESS, // Or address(0) for ETH
    enabled: true
});
```

**Resulting Costs:**

- 0→1: 100 tokens (first appeal)
- 1→2: 150 tokens (to Kleros)
- 2→3: 300 tokens (if hypothetical round 3 existed)

### Anti-Griefing

```solidity
minEscrowValueForEscalation = 1000e18; // $1000 minimum to escalate beyond round 1
```

---

## Phase Gate: v2 → v3 Readiness

**Metrics to Track:**

- Appeal success rate (refund rate)
- Average bond amount
- Escalation depth distribution
- Bonds paid to resolvers vs protocol
- Resolver behavior changes (decision quality)

**V2 Exit Criteria (before v3):**

- Stable appeal economics (20-40% reversal rate)
- No evidence of resolver collusion
- Predictable bond flows (not excessive refunds or forfeitures)
- Kleros escalation rate <5% (system self-resolves)

---

## Testing Status

**Current:** ✅ 107 tests passing (all v1 tests)

**Needed for v2:**

- [ ] Appeal bond recording and tracking
- [ ] Bond refund on successful appeal
- [ ] Bond payment to resolvers on failed appeal
- [ ] Bond forfeiture on escalator no-show
- [ ] Cost curve calculations (linear/quadratic/geometric)
- [ ] Governance config changes (slow lane)
- [ ] Anti-griefing rules (minimum escrow value)
- [ ] Observability metrics tracking
- [ ] Integration tests (full escalation flow with bonds)
- [ ] Edge cases (ETH vs ERC20 bonds, rounding, etc.)

**Estimated Test Count:** ~20-25 tests

---

## Next Steps

1. **Create DR v2 Test Suite** (`test/foundry/decentralized-resolution-module/DRv2AppealBonds.t.sol`)
2. **Integration Testing** with full escrow flow
3. **Parameter Tuning** (simulate different cost curves)
4. **Documentation Update** (user guides, integration docs)
5. **Governance Proposal Template** for v2 activation

---

## Future Work (DR v3)

DR v3 will add:

- **Resolver staking** (capital at risk)
- **Slashing** (penalties for bad decisions)
- **Senior backing** (capital delegation)
- **Fraud lane** (off-chain proof submission)

These features are intentionally deferred until v2 proves stable under real usage.

---

## Summary

DR v2 implementation is **feature-complete** with:

- ✅ Appeal bond tracking per dispute/round
- ✅ Bond custody in IncentiveModuleV2
- ✅ Refund/payout logic based on outcome
- ✅ Escalation cost curves (3 types)
- ✅ Anti-griefing measures
- ✅ Observability metrics
- ✅ Governance controls (slow lane)
- ✅ Clean v1→v2 swap path

**What's Missing:** Comprehensive test coverage (next priority)

**Recommendation:** Complete test suite before mainnet deployment. Simulate various cost curve parameters to find optimal defaults.
