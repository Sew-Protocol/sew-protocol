# Token Incentive Verification Plan

**Goal:** Assure that code accurately reflects incentive design and that incentives are robust and well-designed.

**Timeline:** This week (low-hanging fruit), with follow-up phases for deeper analysis.

**Approach:** Ordered by effort/value ratio - start with quick wins that catch bugs, then progressively deeper analysis.

---

## Phase 1: Quick Wins (This Week)

### 1.1 Payment Formula Cross-Check (2-3 hours)
**Goal:** Verify code matches documented formulas

**Tasks:**
- [ ] Create spreadsheet/hand-calculations for payment scenarios
  - Single resolver, level 0 (1x weight)
  - Multiple resolvers, mixed levels (1x, 1.5x, 2x weights)
  - Edge cases: 0 fees, 100% resolver share, minimum amounts
- [ ] Compare against `PaymentCalculationLibraryV1.calculatePayment()`
- [ ] Document any discrepancies
- [ ] Create unit tests with pre-calculated expected values

**Files to verify:**
- `contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol`
- `docs/dispute-resolution/RESOLVER_ECONOMICS.md` (payment formulas)
- Existing tests: `test/foundry/core/ResolverIncentiveModuleComprehensive.t.sol`

**Deliverable:** Test file with hand-verified payment calculations

---

### 1.2 Payment Invariants Tests (2-3 hours)
**Goal:** Verify mathematical properties hold regardless of inputs

**Invariants to test:**
- [ ] **Invariant 1:** `sum(payments) == totalResolverShare` (within rounding tolerance)
- [ ] **Invariant 2:** `totalResolverShare == (totalFees * resolverSharePercentage) / BASIS_POINTS`
- [ ] **Invariant 3:** Higher level resolvers get more (or equal if same level)
- [ ] **Invariant 4:** No payment exceeds total available (no over-allocation)
- [ ] **Invariant 5:** Payments are non-negative
- [ ] **Invariant 6:** Zero fees → zero payments
- [ ] **Invariant 7:** Zero resolver share % → zero payments

**Implementation:**
- Use Foundry invariant tests or property-based tests
- Fuzz inputs (fees, resolver counts, levels, weights)

**Deliverable:** `test/foundry/decentralized-resolution-module/PaymentCalculationInvariants.t.sol`

---

### 1.3 Appeal Bond Distribution Logic Check (2-3 hours)
**Goal:** Verify bond distribution matches design (refund on success, pay resolvers on failure)

**Scenarios to verify:**
- [ ] Appeal succeeds (outcome flipped) → bond refunded to depositor
- [ ] Appeal fails (outcome upheld) → bond paid to prior round resolvers
- [ ] Multiple resolvers at prior round → bond split equally
- [ ] No resolvers at prior round → bond retained by protocol (edge case)
- [ ] Rounding when splitting bond across multiple resolvers

**Files to verify:**
- `contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol`:
  - `distributeAppealBond()` (lines ~180-210)
  - `_refundBond()` (lines ~217-236)
  - `_payBondToResolvers()` (lines ~246-310)
- Documentation: `docs/dispute-resolution/RESOLVER_ECONOMICS.md` (Section 1.1)

**Deliverable:** Test file with explicit scenarios and expected outcomes

---

### 1.4 Bond Cost Curve Verification (1-2 hours)
**Goal:** Verify bond calculation matches quadratic/geometric curve design

**Tasks:**
- [ ] Locate bond calculation in `DecentralizedResolutionModule`
- [ ] Extract formula (should be: `base + step * k^2` for quadratic)
- [ ] Create test cases:
  - Round 0 → 1: bond amount = base
  - Round 1 → 2: bond amount = base + step * 1^2
  - Round 2 → 3: bond amount = base + step * 2^2
- [ ] Verify increasing cost (each round more expensive)
- [ ] Verify curve parameters are configurable (if applicable)

**Files to verify:**
- `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- `docs/dispute-resolution/RESOLVER_ECONOMICS.md` (Section 1.2)

**Deliverable:** Test file verifying bond curve calculations

---

### 1.5 Resolver Share Percentage Boundaries (1 hour)
**Goal:** Verify resolver share percentage behaves correctly at boundaries

**Edge cases:**
- [ ] `resolverSharePercentage = 0` → no payments to resolvers
- [ ] `resolverSharePercentage = 10000` (100%) → all fees to resolvers, none to protocol
- [ ] `resolverSharePercentage = 5000` (50%) → half to resolvers, half to protocol
- [ ] Verify `resolverSharePercentage` cannot exceed 10000

**Files to verify:**
- `contracts/decentralized-resolution-module/ResolverIncentiveModuleV1.sol`
- `PaymentCalculationLibraryV1.sol`

**Deliverable:** Edge case tests

---

### 1.6 Documentation-to-Code Alignment Check (2 hours)
**Goal:** Ensure all incentive mechanisms in docs are implemented in code

**Checklist:**
- [ ] Payment calculation (weighted by level) - **Status:** ✅ Implemented
- [ ] Appeal bonds (refund on success, pay resolvers on failure) - **Status:** ✅ Implemented
- [ ] Bond cost curves (quadratic) - **Status:** ⚠️ Verify implementation
- [ ] Escalation delays (increasing with depth) - **Status:** ⚠️ Verify implementation
- [ ] Resolver share percentage - **Status:** ✅ Implemented
- [ ] Workload routing (performance-based) - **Status:** ⚠️ Verify implementation
- [ ] Reputation/EMA scoring - **Status:** ⏸️ Deferred (not yet implemented)
- [ ] Staking/slashing (DR v3) - **Status:** ⚠️ Verify implementation

**Deliverable:** Markdown document with implementation status matrix

---

## Phase 2: Property Testing (This Week, if time permits)

### 2.1 Payment Calculation Fuzz Tests (2-3 hours)
**Goal:** Find edge cases and rounding errors through random inputs

**Tests:**
- [ ] Fuzz resolver count (1-10 resolvers)
- [ ] Fuzz fee amounts (1 wei to 1e30, various token decimals)
- [ ] Fuzz resolver levels (0, 1, 2)
- [ ] Fuzz resolver share percentage (0-10000 bps)
- [ ] Verify no overflows, no underflows, no precision loss beyond acceptable rounding

**Deliverable:** Fuzz test suite

---

### 2.2 Appeal Bond Distribution Fuzz Tests (2 hours)
**Goal:** Test bond distribution with varied inputs

**Tests:**
- [ ] Fuzz bond amounts (1 wei to 1e30)
- [ ] Fuzz resolver counts at prior round (0-10 resolvers)
- [ ] Fuzz ETH vs ERC20 bonds
- [ ] Verify rounding when splitting bonds across resolvers

**Deliverable:** Fuzz test suite for bond distribution

---

## Phase 3: Integration Verification (This Week, if time permits)

### 3.1 End-to-End Payment Flow Test (2 hours)
**Goal:** Verify complete payment flow from dispute → resolution → payment

**Test scenario:**
1. Create escrow with dispute
2. Record resolvers at multiple levels
3. Record escrow fee
4. Resolve dispute
5. Call `onDisputeResolved()`
6. Resolvers claim payments
7. Verify:
   - Correct total distributed
   - Correct per-resolver amounts
   - Protocol receives remainder

**Deliverable:** Integration test with explicit assertions

---

### 3.2 End-to-End Appeal Bond Flow Test (2 hours)
**Goal:** Verify complete appeal bond flow from deposit → resolution → distribution

**Test scenarios:**
- [ ] Successful appeal path:
  1. Initial resolution
  2. User posts bond
  3. Appeal to next round
  4. Outcome flips
  5. Bond refunded to depositor
- [ ] Failed appeal path:
  1. Initial resolution
  2. User posts bond
  3. Appeal to next round
  4. Outcome upheld
  5. Bond paid to prior round resolvers

**Deliverable:** Integration tests for both paths

---

## Phase 4: Economic Design Review (Next Week / Later)

### 4.1 Incentive Alignment Analysis
**Goal:** Verify incentives align resolver behavior with protocol goals

**Questions to answer:**
- Do payment weights encourage quality? (Higher levels get more)
- Do appeal bonds discourage griefing? (Cost increases with depth)
- Are there perverse incentives? (e.g., resolvers might collude)
- Do incentives scale with risk? (More complex disputes → more payment)

**Deliverable:** Written analysis document

---

### 4.2 Attack Vector Verification
**Goal:** Verify documented attack vectors are mitigated by incentives

**Check against `RESOLVER_ECONOMICS.md` Section 9:**
- [ ] Griefing: Increasing bonds + deadlines prevent spam
- [ ] Appeal spam: Bonds paid to resolvers on failure
- [ ] Bribery: Random assignment + escalation bonds reduce incentive
- [ ] Latency games: SLAs + penalties reduce delay incentives

**Deliverable:** Matrix showing attack → mitigation → code location

---

### 4.3 Parameter Sensitivity Analysis (Future)
**Goal:** Understand how parameter changes affect incentives

**Parameters to analyze:**
- `resolverSharePercentage` (what if too high/low?)
- Bond curve parameters (what if too steep/flat?)
- Weight configuration (what if level 2 gets 10x instead of 2x?)

**Note:** This requires simulation/modeling - defer to later phase

---

## Phase 5: Simulation & Modeling (Future - Not This Week)

### 5.1 Payment Distribution Simulation
**Goal:** Model payment distribution under various scenarios

**Simulate:**
- 1000 disputes with varied resolver counts/levels
- Distribution of payments over time
- Identify any unexpected patterns (e.g., certain resolvers always underpaid)

**Note:** Requires simulation framework - defer

---

### 5.2 Economic Model Validation
**Goal:** Verify incentives produce desired economic outcomes

**Model:**
- Resolver behavior under different incentive structures
- Attack profitability (should be negative)
- Protocol sustainability (fees cover costs)

**Note:** Requires economic modeling - defer

---

## Summary Checklist

### This Week (Phase 1):
- [ ] Payment formula cross-check (hand calculations vs code)
- [ ] Payment invariants tests (mathematical properties)
- [ ] Appeal bond distribution logic check (refund vs pay)
- [ ] Bond cost curve verification (quadratic formula)
- [ ] Resolver share percentage boundaries
- [ ] Documentation-to-code alignment

### If Time Permits (Phase 2-3):
- [ ] Payment calculation fuzz tests
- [ ] Appeal bond fuzz tests
- [ ] End-to-end payment flow test
- [ ] End-to-end appeal bond flow test

### Later (Phase 4-5):
- [ ] Incentive alignment analysis
- [ ] Attack vector verification
- [ ] Parameter sensitivity analysis
- [ ] Full simulation
- [ ] Economic model validation

---

## Expected Outcomes

**By end of week:**
1. ✅ High confidence that payment formulas are correct
2. ✅ High confidence that appeal bonds work as designed
3. ✅ Documented gaps between design and implementation
4. ✅ Test coverage for critical incentive paths
5. ✅ List of potential improvements or edge cases to address

**Risk mitigation:**
- Catch calculation bugs early (before mainnet)
- Identify design flaws (e.g., rounding issues)
- Ensure code matches documentation (prevent confusion)

---

## Tools & Resources

**Testing Framework:**
- Foundry (already in use)
- Property-based testing via fuzz/invariant tests

**Reference Documents:**
- `docs/dispute-resolution/RESOLVER_ECONOMICS.md` - Incentive design
- `docs/WHITEPAPER.md` - High-level incentive description
- `contracts/decentralized-resolution-module/` - Implementation

**Helper Scripts (create if needed):**
- Payment calculator script (JS/Python) for hand verification
- Bond curve calculator for verification

---

## Notes

- **Focus on correctness first, optimization later**
- **Document all assumptions** (e.g., rounding behavior)
- **Create reusable test utilities** for common scenarios
- **Prioritize scenarios most likely to occur** (e.g., 1-3 resolvers, not 100)
- **Keep tests readable** - use descriptive names and comments
