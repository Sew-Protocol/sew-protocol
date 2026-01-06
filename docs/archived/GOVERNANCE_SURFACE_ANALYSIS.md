# Governance Surface Analysis: Current State vs. Credible Upgrades Plan

## Executive Summary

This document analyzes the current governance surface of the Sew Protocol contracts against the recommendations in `Credible_upgrades.md`. It identifies:
- What admin functions currently exist
- How they map to governance lanes (Slow/Standard/Emergency)
- What infrastructure exists vs. what needs to be built
- Work required to implement the credible upgrades pattern

---

## Current Admin Functions Inventory

### BaseEscrow.sol

#### Owner-Only Functions (Currently `onlyOwner`)

1. **`setDefaultAutoCancelTime(uint256 time)`**
   - Risk Level: Medium
   - Current Access: Owner only
   - Governance Lane: Standard (parameter within bounds)

2. **`setDefaultAutoReleaseTime(uint256 time)`**
   - Risk Level: Medium
   - Current Access: Owner only
   - Governance Lane: Standard (parameter within bounds)

3. **`setEscrowFeeAddress(address feeAddress)`**
   - Risk Level: High
   - Current Access: Owner only
   - Governance Lane: Slow (affects fee collection)

4. **`setEscrowFee(uint256 newFee)`**
   - Risk Level: High
   - Current Access: Owner only
   - Governance Lane: Slow (affects fee rates, must respect bounds)

5. **`setMaxAttachments(uint256 newMax)`**
   - Risk Level: Low-Medium
   - Current Access: Owner only
   - Governance Lane: Standard (operational parameter)

6. **`pause()`**
   - Risk Level: Emergency
   - Current Access: Owner only
   - Governance Lane: Emergency (guardian multisig)

7. **`unpause()`**
   - Risk Level: Emergency
   - Current Access: Owner only
   - Governance Lane: Emergency (guardian multisig)

8. **`setAuthorizedResolver(address resolver)`**
   - Risk Level: High
   - Current Access: Owner only
   - Governance Lane: Slow (affects dispute resolution)

9. **`setDao(address newDao)`**
   - Risk Level: High
   - Current Access: Owner only
   - Governance Lane: Slow (governance infrastructure change)

#### DAO or Owner Functions (`onlyDaoOrOwner`)

10. **`setResolutionModuleDelay(uint256 newDelay)`**
    - Risk Level: Medium
    - Current Access: DAO or Owner
    - Governance Lane: Standard (timelock parameter)

11. **`proposeResolutionModule(address newModule)`**
    - Risk Level: High
    - Current Access: DAO or Owner
    - Governance Lane: Slow (module swap - two-step pattern exists!)

12. **`activateResolutionModule()`**
    - Risk Level: High
    - Current Access: DAO or Owner
    - Governance Lane: Slow (module activation after delay)

#### Owner-Only Yield Distribution Functions

13. **`setDefaultYieldDistribution(address[] recipients, uint256[] percentages)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (yield distribution parameters)

14. **`setEscrowYieldDistribution(uint256 workflowId, address[] recipients, uint256[] percentages)`**
    - Risk Level: Low
    - Current Access: Owner only
    - Governance Lane: Standard (per-escrow setting)

---

### EscrowableERC20.sol

#### Owner-Only Module Setter Functions

15. **`setReleaseStrategyForEscrow(uint256 workflowId, address strategy)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (per-escrow override)

16. **`setResolutionModuleForEscrow(uint256 workflowId, address module)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (per-escrow override)

17. **`setYieldGenerationModuleForEscrow(uint256 workflowId, address module)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (per-escrow override)

18. **`setYieldDistributionModuleForEscrow(uint256 workflowId, address module)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (per-escrow override)

#### Owner-Only Default Module Setters

19. **`setDefaultReleaseStrategy(address strategy)`**
    - Risk Level: High
    - Current Access: Owner only
    - Governance Lane: Slow (default module swap)

20. **`setDefaultResolutionModule(address module)`**
    - Risk Level: High
    - Current Access: Owner only
    - Governance Lane: Slow (default module swap)

21. **`setDefaultYieldGenerationModule(address module)`**
    - Risk Level: High
    - Current Access: Owner only
    - Governance Lane: Slow (default module swap)

22. **`setDefaultYieldDistributionModule(address module)`**
    - Risk Level: High
    - Current Access: Owner only
    - Governance Lane: Slow (default module swap)

---

### EscrowVault.sol

EscrowVault inherits from BaseEscrow and has the same module setter functions (15-22 above), plus:

23. **`withdrawFees(address token)`** (inherited, fee address only)
    - Risk Level: Low
    - Current Access: Fee address
    - Governance Lane: Standard (fee withdrawal)

---

### Module Contracts

#### AaveYieldGenerationModule.sol

24. **`setAavePoolAddressesProvider(address provider)`**
    - Risk Level: High
    - Current Access: Owner only
    - Governance Lane: Slow (yield provider configuration)

25. **`setAaveEnabled(bool enabled)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (enable/disable yield)

26. **`registerTokenForAave(address token, address aToken)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (asset registration)

27. **`batchRegisterTokensForAave(address[] tokens, address[] aTokens)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (batch asset registration)

#### DefaultResolutionModule.sol

28. **`setResolver(address newResolver)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (resolver address update)

#### DecentralizedResolutionModule.sol

29. **`setEscalationConfig(uint8 level, EscalationConfig memory config)`**
    - Risk Level: High
    - Current Access: Owner only
    - Governance Lane: Slow (dispute resolution configuration)

30. **`setExternalResolver(address resolver)`**
    - Risk Level: Medium
    - Current Access: Owner only
    - Governance Lane: Standard (external resolver address)

---

## What Exists vs. What's Needed

### ✅ What Already Exists

1. **Modular Architecture**
   - ✅ Swappable modules via interfaces (IResolutionModule, IReleaseStrategy, IYieldGenerationModule, IYieldDistributionModule)
   - ✅ Default modules + per-escrow overrides
   - ✅ Module validation via ERC-165

2. **Two-Step Module Change Pattern** (Partial)
   - ✅ `proposeResolutionModule()` - queues new module
   - ✅ `activateResolutionModule()` - activates after delay
   - ✅ `resolutionModuleDelay` - configurable delay
   - ✅ Only implemented for `resolutionModule`, not other modules

3. **DAO Support** (Partial)
   - ✅ `setDao()` function exists
   - ✅ `onlyDaoOrOwner` modifier exists
   - ✅ Used for resolution module changes
   - ❌ Not used for other admin functions

4. **Settings Validation**
   - ✅ `SettingsValidationLibrary` exists
   - ✅ Bounds checking for fees, times, etc.
   - ✅ Used in escrow creation

5. **Emergency Controls**
   - ✅ `pause()` / `unpause()` functions
   - ✅ `whenNotPaused` modifier
   - ❌ No guardian role separation

6. **Events**
   - ✅ Events for most state changes
   - ✅ Module change events
   - ✅ Settings update events

### ❌ What's Missing (Per Credible_upgrades.md)

1. **Centralized Settings Registry**
   - ❌ No `EscrowSettings.sol` contract
   - ❌ Module addresses stored in individual contracts
   - ❌ No single source of truth for governance surface

2. **Role-Based Access Control (RBAC)**
   - ❌ No `DEFAULT_ADMIN_ROLE` (should be Timelock)
   - ❌ No `GUARDIAN_ROLE` (for emergency actions)
   - ❌ No `PARAMETER_ROLE` (for low-risk parameter tweaks)
   - ✅ Currently uses simple `Ownable` pattern

3. **Two-Step Module Changes for All Modules**
   - ✅ Resolution module has two-step pattern
   - ❌ Release strategy: direct setter only
   - ❌ Yield generation module: direct setter only
   - ❌ Yield distribution module: direct setter only

4. **Governance Lanes Implementation**
   - ❌ No explicit "Slow Lane" (timelock for module swaps)
   - ❌ No explicit "Standard Lane" (shorter timelock for parameters)
   - ❌ No explicit "Emergency Lane" (guardian-only, immediate)

5. **Onchain Bounds Enforcement**
   - ✅ Validation library exists
   - ❌ No onchain enforcement of bounds (e.g., `maxFeeBps <= 200`)
   - ❌ No versioned settings structs

6. **Module Registry Pattern**
   - ❌ No centralized module registry
   - ❌ No interface compliance checks at registry level
   - ❌ No module versioning

7. **Progressive Rollout Support**
   - ❌ No `ResolutionRouter` module for percentage-based routing
   - ❌ No cohort configuration for gradual module adoption

8. **Timelock Integration**
   - ❌ No TimelockController deployed
   - ❌ No Governor contract deployed
   - ❌ Admin functions not routed through Timelock

9. **Documentation**
   - ❌ No governance surface map (roles → functions → risk lane → delay)
   - ❌ No module map (interface → implementation → change mechanism)
   - ❌ No upgrade policy document
   - ❌ No emergency policy document

---

## Governance Lane Mapping

### Lane 1: Slow (Module Changes + High-Risk Settings)
**Timelock Delay**: 7 days (per CONTRACTS_ADDITION_PLAN.md)  
**Required**: Onchain vote via Governor

**Functions that should be in Slow Lane:**
- `setDefaultReleaseStrategy()` - Module swap
- `setDefaultResolutionModule()` - Module swap (has two-step, but not timelocked)
- `setDefaultYieldGenerationModule()` - Module swap
- `setDefaultYieldDistributionModule()` - Module swap
- `setEscrowFeeAddress()` - High-risk (fee collection)
- `setEscrowFee()` - High-risk (within bounds)
- `setAuthorizedResolver()` - High-risk (dispute resolution)
- `setDao()` - High-risk (governance infrastructure)
- `setAavePoolAddressesProvider()` - High-risk (yield provider)
- `setEscalationConfig()` - High-risk (dispute resolution config)

**Current State**: All are `onlyOwner`, no timelock, no onchain vote

### Lane 2: Standard (Medium-Risk Parameters)
**Timelock Delay**: 24-72 hours (shorter than Slow Lane)  
**Required**: Onchain vote (or delegated council)

**Functions that should be in Standard Lane:**
- `setDefaultAutoCancelTime()` - Parameter within bounds
- `setDefaultAutoReleaseTime()` - Parameter within bounds
- `setMaxAttachments()` - Operational threshold
- `setResolutionModuleDelay()` - Timelock parameter
- `setAaveEnabled()` - Enable/disable yield
- `registerTokenForAave()` - Asset registration
- `batchRegisterTokensForAave()` - Batch asset registration
- `setResolver()` (DefaultResolutionModule) - Resolver address
- `setExternalResolver()` - External resolver address
- `setDefaultYieldDistribution()` - Yield distribution parameters
- `setEscrowYieldDistribution()` - Per-escrow yield distribution

**Current State**: All are `onlyOwner`, no timelock, no onchain vote

### Lane 3: Emergency (Guardian Multisig)
**Timelock Delay**: Immediate  
**Scope**: Extremely limited

**Functions that should be in Emergency Lane:**
- `pause()` - Pause new escrow creation
- `unpause()` - Unpause (with DAO ratification requirement)

**Current State**: `onlyOwner`, no guardian role separation

**Functions that should NOT be in Emergency Lane (but currently are):**
- Module swaps (too powerful)
- Fee changes (too powerful)
- Resolver changes (too powerful)

---

## Work Required

### Phase 1: Infrastructure Setup (Week 1)

#### 1.1 Deploy Governance Infrastructure
- [ ] Deploy TimelockController (7-day delay)
- [ ] Deploy GovernorTimelockControl (Sew Protocol DAO)
- [ ] Deploy Safe Multisig (3-of-5)
- [ ] Deploy SewToken (ERC20Votes, 1B supply)

#### 1.2 Transfer Ownership
- [ ] Transfer contract ownership: Deployer → Safe Multisig
- [ ] Transfer Safe ownership: Safe → Timelock
- [ ] Grant Governor proposer/executor roles in Timelock
- [ ] Transfer contract ownership: Safe → Timelock (via governance)

### Phase 2: Create EscrowSettings Contract (Week 2)

#### 2.1 Design and Implement
- [ ] Create `contracts/governance/EscrowSettings.sol`
  - Store all module addresses
  - Store parameter settings structs
  - Enforce interface compliance (ERC-165)
  - Enforce bounds via SettingsValidationLibrary
  - Emit events for every change
  - Use OpenZeppelin AccessControl for roles

#### 2.2 Access Control Setup
- [ ] `DEFAULT_ADMIN_ROLE`: Timelock address
- [ ] `GUARDIAN_ROLE`: Guardian multisig (narrow scope)
- [ ] `PARAMETER_ROLE`: Optional, for low-risk tweaks

#### 2.3 Migration
- [ ] Update BaseEscrow to read from EscrowSettings
- [ ] Update EscrowableERC20 to read from EscrowSettings
- [ ] Update EscrowVault to read from EscrowSettings
- [ ] Migrate existing module addresses to EscrowSettings

### Phase 3: Implement Two-Step Module Changes (Week 2-3)

#### 3.1 Extend Two-Step Pattern
- [ ] Add `proposeReleaseStrategy()` + `activateReleaseStrategy()`
- [ ] Add `proposeYieldGenerationModule()` + `activateYieldGenerationModule()`
- [ ] Add `proposeYieldDistributionModule()` + `activateYieldDistributionModule()`
- [ ] Add delay parameters for each module type

#### 3.2 Timelock Integration
- [ ] Route all module proposals through Timelock
- [ ] Route all module activations through Timelock
- [ ] Ensure delays are enforced onchain

### Phase 4: Implement Governance Lanes (Week 3)

#### 4.1 Slow Lane
- [ ] Route high-risk functions through Governor → Timelock
- [ ] Ensure 7-day delay is enforced
- [ ] Add onchain vote requirement

#### 4.2 Standard Lane
- [ ] Route medium-risk functions through Governor → Timelock
- [ ] Use shorter delay (24-72 hours)
- [ ] Add onchain vote requirement

#### 4.3 Emergency Lane
- [ ] Create `GUARDIAN_ROLE`
- [ ] Restrict guardian to `pause()` / `unpause()` only
- [ ] Add DAO ratification requirement for unpause
- [ ] Add automatic expiry of emergency state

### Phase 5: Onchain Bounds Enforcement (Week 3-4)

#### 5.1 Bounds Implementation
- [ ] Add `maxFeeBps` constant (e.g., 200 = 2%)
- [ ] Enforce bounds in EscrowSettings contract
- [ ] Add versioned settings structs
- [ ] Emit "SettingsChanged" events with old/new digests

#### 5.2 Parameter Validation
- [ ] Move bounds checking to EscrowSettings
- [ ] Ensure all parameter changes respect bounds
- [ ] Add special "slow lane" proposal type for bound changes

### Phase 6: Progressive Rollout Support (Week 4, Optional)

#### 6.1 ResolutionRouter Module
- [ ] Create `contracts/modules/ResolutionRouter.sol`
- [ ] Implement IResolutionModule
- [ ] Add deterministic routing (hash-based)
- [ ] Add cohort configuration (percentage + allowlist)

#### 6.2 Integration
- [ ] Route resolution through ResolutionRouter
- [ ] Add governance controls for routing percentages
- [ ] Ensure transparency (no owner-chosen routing)

### Phase 7: Documentation (Week 4)

#### 7.1 Governance Surface Map
- [ ] Document all roles
- [ ] Document all functions per role
- [ ] Document risk lane per function
- [ ] Document timelock delay per lane

#### 7.2 Module Map
- [ ] List each interface
- [ ] List current implementation address
- [ ] Document how each can change
- [ ] Document two-step process

#### 7.3 Policy Documents
- [ ] Upgrade policy (ossification plan)
- [ ] Emergency policy (triggers, scope, reversal)
- [ ] Governance process (forum → vote → timelock → execute)

---

## Current Admin Functions Summary Table

| Function | Contract | Current Access | Risk Level | Target Lane | Status |
|----------|----------|----------------|------------|-------------|--------|
| `setDefaultAutoCancelTime` | BaseEscrow | Owner | Medium | Standard | Needs Timelock |
| `setDefaultAutoReleaseTime` | BaseEscrow | Owner | Medium | Standard | Needs Timelock |
| `setEscrowFeeAddress` | BaseEscrow | Owner | High | Slow | Needs Timelock |
| `setEscrowFee` | BaseEscrow | Owner | High | Slow | Needs Timelock |
| `setMaxAttachments` | BaseEscrow | Owner | Low-Medium | Standard | Needs Timelock |
| `pause` | BaseEscrow | Owner | Emergency | Emergency | Needs Guardian Role |
| `unpause` | BaseEscrow | Owner | Emergency | Emergency | Needs Guardian Role |
| `setAuthorizedResolver` | BaseEscrow | Owner | High | Slow | Needs Timelock |
| `setDao` | BaseEscrow | Owner | High | Slow | Needs Timelock |
| `setResolutionModuleDelay` | BaseEscrow | DAO/Owner | Medium | Standard | Needs Timelock |
| `proposeResolutionModule` | BaseEscrow | DAO/Owner | High | Slow | ✅ Two-step exists, needs Timelock |
| `activateResolutionModule` | BaseEscrow | DAO/Owner | High | Slow | ✅ Two-step exists, needs Timelock |
| `setDefaultYieldDistribution` | BaseEscrow | Owner | Medium | Standard | Needs Timelock |
| `setEscrowYieldDistribution` | BaseEscrow | Owner | Low | Standard | Needs Timelock |
| `setReleaseStrategyForEscrow` | EscrowableERC20 | Owner | Medium | Standard | Needs Timelock |
| `setResolutionModuleForEscrow` | EscrowableERC20 | Owner | Medium | Standard | Needs Timelock |
| `setYieldGenerationModuleForEscrow` | EscrowableERC20 | Owner | Medium | Standard | Needs Timelock |
| `setYieldDistributionModuleForEscrow` | EscrowableERC20 | Owner | Medium | Standard | Needs Timelock |
| `setDefaultReleaseStrategy` | EscrowableERC20 | Owner | High | Slow | Needs Two-step + Timelock |
| `setDefaultResolutionModule` | EscrowableERC20 | Owner | High | Slow | Needs Two-step + Timelock |
| `setDefaultYieldGenerationModule` | EscrowableERC20 | Owner | High | Slow | Needs Two-step + Timelock |
| `setDefaultYieldDistributionModule` | EscrowableERC20 | Owner | High | Slow | Needs Two-step + Timelock |
| `setAavePoolAddressesProvider` | AaveYieldModule | Owner | High | Slow | Needs Timelock |
| `setAaveEnabled` | AaveYieldModule | Owner | Medium | Standard | Needs Timelock |
| `registerTokenForAave` | AaveYieldModule | Owner | Medium | Standard | Needs Timelock |
| `batchRegisterTokensForAave` | AaveYieldModule | Owner | Medium | Standard | Needs Timelock |
| `setResolver` | DefaultResolutionModule | Owner | Medium | Standard | Needs Timelock |
| `setEscalationConfig` | DecentralizedResolutionModule | Owner | High | Slow | Needs Timelock |
| `setExternalResolver` | DecentralizedResolutionModule | Owner | Medium | Standard | Needs Timelock |

**Total Admin Functions**: 28  
**Functions with Two-Step Pattern**: 2 (resolution module only)  
**Functions Routed Through Timelock**: 0  
**Functions with Guardian Role**: 0  
**Functions with Onchain Vote**: 0

---

## Key Gaps to Address

1. **No Timelock Integration**: All admin functions are directly callable by owner
2. **No Governor Integration**: No onchain voting mechanism
3. **No Role Separation**: Single `onlyOwner` for all functions
4. **Incomplete Two-Step Pattern**: Only resolution module has it
5. **No Centralized Settings**: Module addresses scattered across contracts
6. **No Bounds Enforcement**: Bounds exist in library but not enforced onchain
7. **No Emergency Role**: Pause/unpause same as other admin functions

---

## Next Steps

1. **Immediate**: Deploy governance infrastructure (Timelock, Governor, Safe, Token)
2. **Week 2**: Create EscrowSettings contract and migrate module storage
3. **Week 3**: Implement two-step pattern for all modules and integrate Timelock
4. **Week 4**: Implement governance lanes and create documentation

See `CONTRACTS_ADDITION_PLAN.md` for detailed implementation plan.


