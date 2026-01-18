# Size Reduction & Appeal Bond Restrictions Implementation Plan

**Date**: 2026-01-XX  
**Priority**: CRITICAL - Blocking mainnet deployment

---

## Part 1: Appeal Bond Restrictions

### 1. Identity + Authorization Restrictions

**Current State**: 
- `escalateDispute()` can be called by anyone
- No verification that appellant is the loser of current round
- No check that depositor equals escalator

**Required Changes**:

1. **Only sender/recipient may appeal**:
   - Add check in `BaseEscrow.escalateDispute()`: `require(_msgSender() == et.from || _msgSender() == et.to, 'NotParticipant')`

2. **Appellant must be the loser**:
   - In `DecentralizedResolutionModule.canEscalate()` or `DisputeOps.computeEscalation()`:
     - If last decision == RELEASE → only `from` (sender) can appeal
     - If last decision == CANCEL → only `to` (recipient) can appeal

3. **Exactly one bond per escalation step**:
   - Already enforced: `require(appealBonds[workflowId][toRound].amount == 0, 'Bond already exists')`

4. **Depositor must equal escalator**:
   - In `BaseEscrow.escalateDispute()`: `require(depositor == _msgSender(), 'DepositorMustBeEscalator')`

### 2. Token Restrictions

**Current State**:
- Bond token can differ from escrow token
- ETH bonds allowed for ERC20 escrows
- No whitelist for bond tokens

**Required Changes**:

1. **Bond token MUST equal escrow token** (launch-safe):
   - In `BaseEscrow.escalateDispute()`: `require(bondToken == et.token, 'BondTokenMustMatchEscrowToken')`

2. **Disallow ETH bonds for ERC20 escrows**:
   - If `et.token != address(0)`: `require(bondToken != address(0), 'NoETHBondsForERC20Escrows')`

3. **Whitelist bond tokens** (future):
   - Add `mapping(address => bool) public approvedBondTokens`
   - Check: `require(approvedBondTokens[bondToken], 'BondTokenNotWhitelisted')`

4. **Single payout token per dispute**:
   - Already enforced via `_requirePayoutToken()` in `ResolverIncentiveModuleV2`

### 3. Timing + State Restrictions

**Current State**: Some checks exist but need strengthening

**Required Changes**:

1. **Bond can only be posted while DISPUTED**:
   - Already enforced: `require(et.escrowState == EscrowState.DISPUTED, 'TransferNotInDispute')`

2. **Within appeal window for that round**:
   - Check: `require(block.timestamp < appealDeadline, 'AppealWindowExpired')`

3. **Not finalized and not in final round**:
   - Check: `require(!isFinalRound, 'CannotAppealFinalRound')`

4. **Escalation cancels pending settlement**:
   - Already implemented in `BaseEscrow.escalateDispute()`

### 4. Amount Restrictions

**Current State**: Amount is calculated but not strictly validated

**Required Changes**:

1. **Bond amount must equal getRequiredAppealBond() exactly**:
   - Already enforced in `BaseEscrow.escalateDispute()`

2. **Min bond and cap bond relative to escrow size**:
   - Add: `require(bondAmount >= minBond, 'BondBelowMinimum')`
   - Add: `require(bondAmount <= maxBond, 'BondExceedsMaximum')`

### 5. Distribution Restrictions

**Current State**: Fee deducted at posting time (wrong)

**Required Changes**:

1. **Refund is always full on flip**:
   - Remove fee deduction from bond posting
   - Refund full amount if appeal succeeds

2. **Fee applies only on forfeiture**:
   - Deduct fee only when distributing to resolvers (appeal failed)
   - Fee goes to protocol, remainder to resolvers

3. **No eligible resolvers → protocol retained**:
   - If no resolvers eligible, bond goes to protocol treasury
   - Must be sweepable by timelock with events

---

## Part 2: BaseEscrow Size Reduction (~10KB Target)

### A) Remove Revert Strings (HIGHEST IMPACT - ~2-3KB)

**Current Issues**:
- `InvalidAmount(string reason)` - string parameter embeds bytes
- `InvalidAddress(string reason, address addr)` - string parameter embeds bytes
- Multiple string literals in revert calls

**Implementation**:

1. **Replace `InvalidAmount(string)` with specific errors**:
   ```solidity
   error AmountZero();
   error FeeOverflow();
   error NoTokensToRecover();
   error YieldDistributionInvalid(); // For library errors
   error PayoutInvalid(); // For resolver logic errors
   ```

2. **Replace `InvalidAddress(string, address)` with specific errors**:
   ```solidity
   error ZeroDisputeOps();
   error ZeroSettlementOps();
   error InvalidResolutionModule(address module);
   error ModuleNotContract(address module);
   ```

3. **Update all usages**:
   - `revert InvalidAmount('Amount > 0')` → `revert AmountZero()`
   - `revert InvalidAddress('DisputeOps cannot be zero', addr)` → `revert ZeroDisputeOps()`
   - `revert InvalidAddress('SettlementOps not configured', addr)` → `revert ZeroSettlementOps()`
   - `revert InvalidAddress('Resolution module no longer a contract', addr)` → `revert ModuleNotContract(addr)`

**Files to Update**:
- `contracts/types/EscrowTypes.sol` - Remove string parameters
- `contracts/core/BaseEscrow.sol` - Replace all usages
- `contracts/core/EscrowVault.sol` - Replace all usages
- `contracts/core/EscrowableERC20.sol` - Replace all usages
- All libraries using `InvalidAmount`/`InvalidAddress`

**Estimated Savings**: **2-3 KB**

---

### B) Replace String Reasons in Events (~1-2KB)

**Current Issues**:
- `YieldHandlingFailed(..., string reason)`
- `IncentiveModuleCallFailed(..., string functionName, string reason)`
- `DisputeAutoCancelled(..., string reason)`

**Implementation**:

1. **Define reason codes enum**:
   ```solidity
   enum FailureReason {
       UNKNOWN,           // 0
       CALL_FAILED,        // 1
       TIMEOUT,            // 2
       INSUFFICIENT_BALANCE, // 3
       INVALID_MODULE,     // 4
       TRANSFER_FAILED,    // 5
       DEPOSIT_FAILED,     // 6
       WITHDRAWAL_FAILED   // 7
   }
   ```

2. **Replace event signatures**:
   ```solidity
   event YieldHandlingFailed(uint256 indexed workflowId, address indexed token, uint256 amount, uint8 reasonCode);
   event IncentiveModuleCallFailed(uint256 indexed workflowId, bytes4 selector, uint8 reasonCode);
   event DisputeAutoCancelled(uint256 indexed workflowId, uint8 reasonCode);
   ```

3. **Update emissions**:
   - `emit YieldHandlingFailed(..., 'Transfer failed')` → `emit YieldHandlingFailed(..., uint8(FailureReason.TRANSFER_FAILED))`
   - `emit DisputeAutoCancelled(..., 'Timeout')` → `emit DisputeAutoCancelled(..., uint8(FailureReason.TIMEOUT))`

**Estimated Savings**: **1-2 KB**

---

### C) Simplify Try/Catch Patterns (~0.5-1KB)

**Current Issues**:
- Multiple try/catch blocks with string reasons
- Each try/catch adds significant bytecode

**Implementation**:

1. **Replace try/catch with single low-level call**:
   ```solidity
   // Before
   try genModule.depositForYield(...) {
       // success
   } catch Error(string memory reason) {
       emit YieldHandlingFailed(..., reason);
   } catch {
       emit YieldHandlingFailed(..., 'Unknown error');
   }
   
   // After
   (bool success, ) = address(genModule).call(
       abi.encodeWithSelector(IYieldGenerationModule.depositForYield.selector, ...)
   );
   if (!success) {
       emit YieldHandlingFailed(..., uint8(FailureReason.DEPOSIT_FAILED));
   }
   ```

2. **Apply to**:
   - Yield deposit in `createEscrow()`
   - Yield withdrawal in `_handleYieldAndGetActualAmount()`
   - Module calls in `escalateDispute()`

**Estimated Savings**: **0.5-1 KB**

---

### D) Consolidate Events (~0.5-1KB)

**Current Issues**:
- `EscrowTransferAutoCompleted` + `EscrowTransferAutoFailed` → can be one event
- Multiple timeout config events → already have `TimeoutConfigUpdated`

**Implementation**:

1. **Consolidate auto-transfer events**:
   ```solidity
   event EscrowTransferAutoResult(
       uint256 indexed workflowId,
       address indexed recipient,
       address indexed token,
       uint256 amount,
       bool success,
       uint8 reasonCode
   );
   ```

2. **Remove redundant timeout events** (if `TimeoutConfigUpdated` is sufficient):
   - `MaxDisputeDurationUpdated`
   - `AppealWindowDurationUpdated`
   - `DefaultAutoReleaseTimeUpdated`
   - `DefaultAutoCancelTimeUpdated`

**Estimated Savings**: **0.5-1 KB**

---

### E) Remove ERC165 if Not Needed (~0.3-0.5KB)

**Check**: Does BaseEscrow need `supportsInterface()`?

**If not needed**:
- Remove `IERC165` import
- Remove `supportsInterface()` implementation
- Remove interface ID constants

**Estimated Savings**: **0.3-0.5 KB**

---

### F) Move Admin Plumbing to Helper (~1-2KB)

**Current Issues**:
- Multiple queue/activate/getPending functions for fees
- Repetitive slow-lane pattern

**Implementation**:

1. **Create `FeeAdminLib` library** (external):
   ```solidity
   library FeeAdminLib {
       function activateUint(PendingUint storage pending) external returns (uint256);
       function queueUint(PendingUint storage pending, uint256 value) external;
       function getPendingUint(PendingUint storage pending) external view returns (uint256, uint64, bool);
   }
   ```

2. **Or create `FeeController` helper contract**:
   - Holds pending values
   - Exposes queue/activate/getPending
   - BaseEscrow reads current config

**Estimated Savings**: **1-2 KB**

---

### G) Extract createEscrow to CreateOps Helper (~3-5KB) ⭐ **HIGHEST IMPACT**

**Current Issues**:
- `createEscrow()` is large (~150+ lines)
- Many comments, branches, validations
- Try/catch with string reasons

**Implementation**:

1. **Create `CreateOps` contract** (similar to `YieldOps`, `DisputeOps`):
   ```solidity
   contract CreateOps {
       struct CreateResult {
           uint256 workflowId;
           uint256 amountAfterFee;
           uint256 fee;
           address resolver;
           bool yieldEnabled;
       }
       
       function createEscrow(
           address token,
           address to,
           uint256 amount,
           EscrowSettings memory settings,
           // ... other params
       ) external returns (CreateResult memory);
   }
   ```

2. **BaseEscrow.createEscrow() becomes thin wrapper**:
   ```solidity
   function createEscrow(...) external returns (uint256) {
       CreateOps.CreateResult memory result = createOps.createEscrow(...);
       
       // Store struct
       escrowTransfers.push(EscrowTransfer({...}));
       
       // Emit events
       emit EscrowCreated(...);
       
       return result.workflowId;
   }
   ```

**Estimated Savings**: **3-5 KB** (largest single win)

---

## Implementation Order

### Phase 1: Quick Wins (2-3 hours, ~4-6KB savings)
1. ✅ Remove revert strings (A) - **2-3 KB**
2. ✅ Replace string reasons in events (B) - **1-2 KB**
3. ✅ Simplify try/catch (C) - **0.5-1 KB**

### Phase 2: Medium Impact (3-4 hours, ~2-3KB savings)
4. ✅ Consolidate events (D) - **0.5-1 KB**
5. ✅ Remove ERC165 if not needed (E) - **0.3-0.5 KB**
6. ✅ Move admin plumbing (F) - **1-2 KB**

### Phase 3: High Impact (4-6 hours, ~3-5KB savings)
7. ✅ Extract createEscrow to CreateOps (G) - **3-5 KB**

### Phase 4: Appeal Bond Restrictions (4-6 hours)
8. ✅ Implement all appeal bond restrictions

**Total Estimated Savings**: **10-15 KB** (should get under 24KB limit)

---

## Next Steps

1. Start with Phase 1 (quick wins)
2. Measure size after each phase
3. Proceed to Phase 2 if still over limit
4. Implement Phase 3 if needed
5. Add appeal bond restrictions in parallel
