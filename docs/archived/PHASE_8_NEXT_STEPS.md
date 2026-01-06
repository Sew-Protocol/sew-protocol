# Phase 8 Next Steps: Testing vs. Development

## Current Status

### ✅ Completed (Phases 0-7)
- **Phase 0**: Governance infrastructure contracts (SewToken, GovGovernor, SlowLaneQueueActivate)
- **Phase 1**: Deployment scripts for governance infrastructure
- **Phase 2**: Access control migration (Ownable → AccessControl)
- **Phase 3**: Slow lane queue/activate pattern implementation
- **Phase 4**: Guardian emergency controls (down-only)
- **Phase 5**: Per-escrow overrides removed
- **Phase 6**: Bounds enforcement
- **Phase 7**: Module snapshotting (new escrows only)

### 📋 Documentation Added
- `docs/governance.md` - Complete governance policy document
- `docs/gov-details.md` - Detailed recommendations and approach

### ⚠️ Testing Gap
- Only basic `MainnetReleaseSequence.test.ts` exists
- No comprehensive tests for governance features implemented in Phases 0-7
- No tests validating governance.md specifications

---

## Recommendation: Write Comprehensive Test Suite FIRST

### Why Test Before Phase 8 Tooling?

1. **Validation of Implementation**
   - Verify all governance features work as specified in `governance.md`
   - Ensure access control, bounds, and snapshotting behave correctly
   - Catch bugs before building tooling on top

2. **Risk Mitigation**
   - Governance is critical infrastructure - must be thoroughly tested
   - Tests serve as executable documentation
   - Identifies gaps between implementation and specification

3. **Foundation for Tooling**
   - Phase 8 tooling will rely on governance contracts working correctly
   - Tests provide examples for tooling implementation
   - Tooling tests can build on existing test infrastructure

4. **Mainnet Readiness**
   - Comprehensive tests are required before mainnet deployment
   - Tests validate the "new escrows only" guarantee
   - Tests verify emergency controls work as intended

---

## Proposed Test Suite Structure

### 1. Governance Infrastructure Tests (`test/hardhat/governance/`)

#### `01_AccessControl.test.ts`
- ✅ Role grants/revokes (ROLE_TIMELOCK, ROLE_GUARDIAN)
- ✅ Role-based function access
- ✅ Deployer role revocation
- ✅ Timelock as DEFAULT_ADMIN_ROLE

#### `02_SlowLaneQueueActivate.test.ts`
- ✅ Queue functions (queueEscrowFee, queueEscrowFeeAddress, queueDao, etc.)
- ✅ ETA enforcement (7-day delay)
- ✅ Activate functions after ETA
- ✅ Revert on early activation
- ✅ Pending state queries

#### `03_BoundsEnforcement.test.ts`
- ✅ Auto cancel/release time bounds (0-30 days)
- ✅ Max attachments bounds (0-20)
- ✅ Fee bps bounds (0-200)
- ✅ Resolution delay bounds (48h-30 days)
- ✅ Yield distribution validation (1-10 recipients, sum=10000)
- ✅ Out-of-bounds reverts with clear errors

#### `04_GuardianControls.test.ts`
- ✅ Guardian can pause
- ✅ Guardian can disable Aave
- ✅ Guardian can lower caps (down-only)
- ✅ Guardian cannot unpause
- ✅ Guardian cannot raise caps
- ✅ Guardian cannot change fees
- ✅ Guardian cannot swap modules

#### `05_ModuleSnapshotting.test.ts`
- ✅ Modules snapshotted at escrow creation
- ✅ Module swap doesn't affect existing escrows
- ✅ New escrows use new modules
- ✅ Snapshot event emission
- ✅ EscrowVault and EscrowableERC20 both snapshot

#### `06_TimelockIntegration.test.ts`
- ✅ Timelock can execute Standard lane functions
- ✅ Timelock can execute Slow lane queue/activate
- ✅ 48-hour delay enforcement
- ✅ Non-timelock cannot execute timelock functions
- ✅ Timelock role configuration

#### `07_GovernorProposalFlow.test.ts`
- ✅ Proposal creation
- ✅ Voting
- ✅ Proposal queuing to Timelock
- ✅ Timelock execution after delay
- ✅ Slow lane proposal flow (queue → wait → activate)

### 2. Integration Tests (`test/hardhat/integration/`)

#### `GovernanceEndToEnd.test.ts`
- ✅ Complete governance flow: propose → vote → queue → execute
- ✅ Slow lane end-to-end: queue → wait 7d → activate
- ✅ Module swap with existing escrows unaffected
- ✅ Emergency pause → timelock unpause flow

#### `NewEscrowsOnly.test.ts`
- ✅ Create escrow with Module A
- ✅ Swap to Module B via governance
- ✅ Existing escrow still uses Module A
- ✅ New escrow uses Module B
- ✅ Verify snapshot addresses match original modules

### 3. Foundry Tests (`test/foundry/governance/`)

#### `AccessControl.t.sol`
- Gas-optimized role checks
- Fuzz testing for role grants

#### `BoundsValidation.t.sol`
- Fuzz testing for bounds
- Edge case testing (min, max, boundaries)

#### `SlowLane.t.sol`
- Time-based testing with `vm.warp`
- ETA enforcement

#### `ModuleSnapshot.t.sol`
- Snapshot integrity checks
- Module swap scenarios

---

## Test Implementation Plan

### Phase A: Core Governance Tests (Priority 1)
1. Access control tests
2. Bounds enforcement tests
3. Slow lane queue/activate tests
4. Module snapshotting tests

**Estimated Time**: 2-3 days

### Phase B: Integration Tests (Priority 2)
1. End-to-end governance flows
2. New escrows only verification
3. Emergency controls integration

**Estimated Time**: 1-2 days

### Phase C: Foundry Tests (Priority 3)
1. Gas optimization tests
2. Fuzz testing
3. Time-based testing

**Estimated Time**: 1-2 days

---

## Alternative: Continue with Phase 8 Development

If you prefer to continue development, Phase 8 would include:

1. **Governance Tooling** (scripts/gov/)
   - Proposal builders
   - Simulation tools
   - Staging tools
   - Emergency tools

2. **Documentation** (docs/)
   - Governance surface map
   - Module map
   - Operational runbooks

**Risk**: Building tooling on untested governance infrastructure could lead to:
- Tooling that doesn't work correctly
- Need to rewrite tooling after fixing governance bugs
- Delayed mainnet deployment

---

## Recommendation Summary

**✅ Write comprehensive test suite FIRST**

**Rationale:**
1. Governance is critical - must be thoroughly tested
2. Tests validate implementation matches governance.md spec
3. Tests catch bugs before building tooling
4. Tests serve as executable documentation
5. Foundation for Phase 8 tooling

**Next Steps:**
1. Create test directory structure
2. Implement Phase A tests (core governance)
3. Implement Phase B tests (integration)
4. Review and fix any issues found
5. Then proceed with Phase 8 tooling

---

## Decision Needed

Please confirm:
- [ ] Write comprehensive test suite first (recommended)
- [ ] Continue with Phase 8 development
- [ ] Hybrid approach (write critical tests, then Phase 8, then remaining tests)


