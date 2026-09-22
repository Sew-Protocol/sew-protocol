# Buyer/Seller Terminology Consistency Plan

**Date**: Current  
**Goal**: Make all terminology consistent with buyer/seller throughout codebase

---

## Current State Analysis

### Inconsistent Terminology Found

1. **Struct Fields**: `from` and `to` (should be `buyer` and `seller`)
2. **Enums**: `SenderStatus` and `RecipientStatus` (should be `BuyerStatus` and `SellerStatus`)
3. **Functions**: `senderCancel()` and `recipientCancel()` (should be `buyerCancel()` and `sellerCancel()`)
4. **Errors**: `NotSender`, `NotRecipient`, `NotParticipant` (should use buyer/seller)
5. **Events**: Use `from` and `to` parameters (should be `buyer` and `seller`)
6. **Function Parameters**: Various functions use `from`/`to` in encoding/decoding
7. **Comments**: Mix of "sender/recipient" and "buyer/seller"

---

## Summary of All Inconsistencies Found

### Terminology Mapping

| Current Term                             | Target Term                          | Context                 | Count |
| ---------------------------------------- | ------------------------------------ | ----------------------- | ----- |
| `from`                                   | `buyer`                              | Struct field, variables | ~80   |
| `to`                                     | `seller`                             | Struct field, variables | ~80   |
| `SenderStatus`                           | `BuyerStatus`                        | Enum definition         | 1     |
| `RecipientStatus`                        | `SellerStatus`                       | Enum definition         | 1     |
| `senderStatus`                           | `buyerStatus`                        | Struct field            | ~10   |
| `recipientStatus`                        | `sellerStatus`                       | Struct field            | ~10   |
| `senderCancel()`                         | `buyerCancel()`                      | Function                | 1     |
| `recipientCancel()`                      | `sellerCancel()`                     | Function                | 1     |
| `NotSender`                              | `NotBuyer`                           | Error                   | ~5    |
| `NotRecipient`                           | `NotSeller`                          | Error                   | ~5    |
| `NotParticipant(..., sender, recipient)` | `NotParticipant(..., buyer, seller)` | Error params            | ~4    |
| Event `from`                             | Event `buyer`                        | Event params            | ~10   |
| Event `to`                               | Event `seller`                       | Event params            | ~10   |
| "sender" in comments                     | "buyer"                              | Comments                | ~20   |
| "recipient" in comments                  | "seller"                             | Comments                | ~20   |

**Total Changes Required**: ~250+ references

---

## Complete Change List

### 1. Struct Fields

**File**: `contracts/BaseEscrow.sol`

**Current**:

```solidity
struct EscrowTransfer {
  address from; // ❌ Should be 'buyer'
  address to; // ❌ Should be 'seller'
  SenderStatus senderStatus; // ❌ Should be 'BuyerStatus buyerStatus'
  RecipientStatus recipientStatus; // ❌ Should be 'SellerStatus sellerStatus'
}
```

**Target**:

```solidity
struct EscrowTransfer {
  address buyer; // ✅ Person paying (was 'from')
  address seller; // ✅ Person receiving (was 'to')
  BuyerStatus buyerStatus; // ✅ (was 'SenderStatus senderStatus')
  SellerStatus sellerStatus; // ✅ (was 'RecipientStatus recipientStatus')
}
```

**References to Update**: ~150+ throughout codebase

---

### 2. Enum Definitions

**File**: `contracts/BaseEscrow.sol`

**Current**:

```solidity
enum SenderStatus {
  NONE,
  AGREE_TO_CANCEL,
  RAISE_DISPUTE
}

enum RecipientStatus {
  NONE,
  AGREE_TO_CANCEL,
  RAISE_DISPUTE
}
```

**Target**:

```solidity
enum BuyerStatus {
  NONE,
  AGREE_TO_CANCEL,
  RAISE_DISPUTE
}

enum SellerStatus {
  NONE,
  AGREE_TO_CANCEL,
  RAISE_DISPUTE
}
```

**References to Update**: ~20+ enum usages

---

### 3. Function Names

**File**: `contracts/BaseEscrow.sol`

**Current**:

```solidity
function senderCancel(uint256 workflowId) public returns (bool)
function recipientCancel(uint256 workflowId) public returns (bool)
```

**Target**:

```solidity
function buyerCancel(uint256 workflowId) public returns (bool)
function sellerCancel(uint256 workflowId) public returns (bool)
```

**References to Update**:

- Function definitions (2)
- Function calls in batch operations (2)
- Documentation/comments

---

### 4. Error Definitions

**File**: `contracts/BaseEscrow.sol`

**Current**:

```solidity
error NotParticipant(uint256 workflowId, address caller, address sender, address recipient);
error NotSender(uint256 workflowId, address caller, address expectedSender);
error NotRecipient(uint256 workflowId, address caller, address expectedRecipient);
```

**Target**:

```solidity
error NotParticipant(uint256 workflowId, address caller, address buyer, address seller);
error NotBuyer(uint256 workflowId, address caller, address expectedBuyer);
error NotSeller(uint256 workflowId, address caller, address expectedSeller);
```

**References to Update**: ~14 error usages

---

### 5. Event Parameters

**Files**: `contracts/BaseEscrow.sol`, `contracts/EscrowVault.sol`, `contracts/EscrowableERC20.sol`

**Current Events** (using `from`/`to`):

```solidity
event EscrowTransferCreated(
  uint256 indexed workflowId,
  address indexed token,
  address indexed from,
  address to,
  uint256 amount
);
event EscrowTransferReleased(
  uint256 indexed workflowId,
  address indexed token,
  address indexed to,
  uint256 amount
);
event EscrowTransferCancelled(
  uint256 indexed workflowId,
  address indexed token,
  address indexed from,
  uint256 amount
);
event EscrowTransferDisputed(
  uint256 indexed workflowId,
  address indexed from,
  address indexed to,
  uint256 amount
);
event EscrowTransferResolved(
  uint256 indexed workflowId,
  address indexed from,
  address indexed to,
  uint256 amount
);
event EscrowTransferResolvedWithPartialRelease(
  uint256 indexed workflowId,
  address indexed from,
  address indexed to,
  uint256 amount
);
event EscrowTransferResolvedWithPartialCancel(
  uint256 indexed workflowId,
  address indexed from,
  address indexed to,
  uint256 amount
);
event EscrowTransferAutoReleased(uint256 indexed workflowId, address indexed to, uint256 amount);
event EscrowTransferAutoCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);
event EvidenceSubmitted(
  uint256 indexed workflowId,
  address indexed from,
  address indexed to,
  string evidence
);
```

**Target Events** (using `buyer`/`seller`):

```solidity
event EscrowTransferCreated(
  uint256 indexed workflowId,
  address indexed token,
  address indexed buyer,
  address seller,
  uint256 amount
);
event EscrowTransferReleased(
  uint256 indexed workflowId,
  address indexed token,
  address indexed seller,
  uint256 amount
);
event EscrowTransferCancelled(
  uint256 indexed workflowId,
  address indexed token,
  address indexed buyer,
  uint256 amount
);
event EscrowTransferDisputed(
  uint256 indexed workflowId,
  address indexed buyer,
  address indexed seller,
  uint256 amount
);
event EscrowTransferResolved(
  uint256 indexed workflowId,
  address indexed buyer,
  address indexed seller,
  uint256 amount
);
event EscrowTransferResolvedWithPartialRelease(
  uint256 indexed workflowId,
  address indexed buyer,
  address indexed seller,
  uint256 amount
);
event EscrowTransferResolvedWithPartialCancel(
  uint256 indexed workflowId,
  address indexed buyer,
  address indexed seller,
  uint256 amount
);
event EscrowTransferAutoReleased(
  uint256 indexed workflowId,
  address indexed seller,
  uint256 amount
);
event EscrowTransferAutoCancelled(
  uint256 indexed workflowId,
  address indexed buyer,
  uint256 amount
);
event EvidenceSubmitted(
  uint256 indexed workflowId,
  address indexed buyer,
  address indexed seller,
  string evidence
);
```

**Note**: Event parameter names don't affect ABI (only types and indexed status), but updating for consistency and documentation clarity.

**References to Update**: ~15 event definitions + ~30 event emissions

---

### 6. Function Parameters and Internal Variables

**Files**: Multiple

**Current**:

- `_encodeResolutionData(address token, address from, address to, ...)`
- `getEscrowParticipants()` returns `(address from, address to)`
- Internal variables: `address from`, `address to`
- Comments: "sender", "recipient"

**Target**:

- `_encodeResolutionData(address token, address buyer, address seller, ...)`
- `getEscrowParticipants()` returns `(address buyer, address seller)`
- Internal variables: `address buyer`, `address seller`
- Comments: "buyer", "seller"

**References to Update**: ~50+ locations

---

### 7. Library Functions

**File**: `contracts/libraries/EscrowEncodingLibrary.sol`

**Current**:

```solidity
function encodeEscrowTransferData(
    address token,
    address from,
    address to,
    uint256 amount,
    uint256 originalAmount
) internal pure returns (bytes memory)

function decodeEscrowTransferData(
    bytes memory data
) internal pure returns (
    address token,
    address from,
    address to,
    uint256 amount,
    uint256 originalAmount
)
```

**Target**:

```solidity
function encodeEscrowTransferData(
    address token,
    address buyer,
    address seller,
    uint256 amount,
    uint256 originalAmount
) internal pure returns (bytes memory)

function decodeEscrowTransferData(
    bytes memory data
) internal pure returns (
    address token,
    address buyer,
    address seller,
    uint256 amount,
    uint256 originalAmount
)
```

**Note**: Parameter names in libraries don't affect ABI, but updating for consistency.

---

### 8. Module Interfaces

**File**: `contracts/modules/DefaultReleaseStrategy.sol`

**Current Comments**:

- "only sender can release"
- "returns recipient and amount"

**Target Comments**:

- "only buyer can release"
- "returns seller and amount"

---

## Implementation Plan

### Phase 1: Core Struct and Enum Changes

**Priority**: HIGH  
**Complexity**: MEDIUM  
**Size Impact**: ~0 bytes (names don't affect bytecode)

1. Rename enum `SenderStatus` → `BuyerStatus`
2. Rename enum `RecipientStatus` → `SellerStatus`
3. Rename struct field `from` → `buyer`
4. Rename struct field `to` → `seller`
5. Rename struct field `senderStatus` → `buyerStatus`
6. Rename struct field `recipientStatus` → `sellerStatus`

**Estimated References**: ~170+ changes

---

### Phase 2: Function Renames

**Priority**: HIGH  
**Complexity**: LOW  
**Size Impact**: ~0 bytes

1. Rename `senderCancel()` → `buyerCancel()`
2. Rename `recipientCancel()` → `sellerCancel()`
3. Update all function calls
4. Update documentation

**Estimated References**: ~10 changes

---

### Phase 3: Error Renames

**Priority**: HIGH  
**Complexity**: LOW  
**Size Impact**: ~0 bytes

1. Rename `NotSender` → `NotBuyer`
2. Rename `NotRecipient` → `NotSeller`
3. Update `NotParticipant` error parameters: `sender, recipient` → `buyer, seller`
4. Update all error usages (~14 locations)

**Estimated References**: ~14 changes

---

### Phase 4: Event Updates

**Priority**: MEDIUM  
**Complexity**: LOW  
**Size Impact**: ~0 bytes (parameter names don't affect ABI)

1. Update event parameter names in definitions
2. Update event emissions to use `buyer`/`seller`
3. Update documentation

**Estimated References**: ~45 changes (15 definitions + 30 emissions)

**Note**: This is cosmetic (parameter names don't affect ABI), but improves consistency.

---

### Phase 5: Function Parameters and Internal Variables

**Priority**: MEDIUM  
**Complexity**: MEDIUM  
**Size Impact**: ~0 bytes

1. Update `_encodeResolutionData()` parameters
2. Update `getEscrowParticipants()` return values
3. Update all internal variable names
4. Update all comments

**Estimated References**: ~50+ changes

---

### Phase 6: Library Updates

**Priority**: LOW  
**Complexity**: LOW  
**Size Impact**: ~0 bytes

1. Update `EscrowEncodingLibrary` parameter names
2. Update comments

**Estimated References**: ~5 changes

---

## Detailed Change Mapping

### BaseEscrow.sol

| Current              | Target            | Type         | Count |
| -------------------- | ----------------- | ------------ | ----- |
| `address from`       | `address buyer`   | Struct field | 1     |
| `address to`         | `address seller`  | Struct field | 1     |
| `SenderStatus`       | `BuyerStatus`     | Enum         | 1     |
| `RecipientStatus`    | `SellerStatus`    | Enum         | 1     |
| `senderStatus`       | `buyerStatus`     | Struct field | 1     |
| `recipientStatus`    | `sellerStatus`    | Struct field | 1     |
| `senderCancel()`     | `buyerCancel()`   | Function     | 1     |
| `recipientCancel()`  | `sellerCancel()`  | Function     | 1     |
| `NotSender`          | `NotBuyer`        | Error        | 1     |
| `NotRecipient`       | `NotSeller`       | Error        | 1     |
| `et.from`            | `et.buyer`        | References   | ~80   |
| `et.to`              | `et.seller`       | References   | ~80   |
| `et.senderStatus`    | `et.buyerStatus`  | References   | ~10   |
| `et.recipientStatus` | `et.sellerStatus` | References   | ~10   |
| `SenderStatus.`      | `BuyerStatus.`    | Enum usage   | ~10   |
| `RecipientStatus.`   | `SellerStatus.`   | Enum usage   | ~10   |
| Event `from`         | Event `buyer`     | Event params | ~10   |
| Event `to`           | Event `seller`    | Event params | ~10   |

**Total BaseEscrow Changes**: ~230+

---

### EscrowVault.sol

| Current                                 | Target                            | Type        | Count |
| --------------------------------------- | --------------------------------- | ----------- | ----- |
| `to: seller`                            | `seller: seller`                  | Struct init | 1     |
| `from: _msgSender()`                    | `buyer: _msgSender()`             | Struct init | 1     |
| `senderStatus: SenderStatus.NONE`       | `buyerStatus: BuyerStatus.NONE`   | Struct init | 1     |
| `recipientStatus: RecipientStatus.NONE` | `sellerStatus: SellerStatus.NONE` | Struct init | 1     |
| Event emissions                         | Update to buyer/seller            | Event calls | ~5    |

**Total EscrowVault Changes**: ~10

---

### EscrowableERC20.sol

| Current                                 | Target                            | Type        | Count |
| --------------------------------------- | --------------------------------- | ----------- | ----- |
| `to: seller`                            | `seller: seller`                  | Struct init | 1     |
| `from: _msgSender()`                    | `buyer: _msgSender()`             | Struct init | 1     |
| `senderStatus: SenderStatus.NONE`       | `buyerStatus: BuyerStatus.NONE`   | Struct init | 1     |
| `recipientStatus: RecipientStatus.NONE` | `sellerStatus: SellerStatus.NONE` | Struct init | 1     |
| Event emissions                         | Update to buyer/seller            | Event calls | ~5    |

**Total EscrowableERC20 Changes**: ~10

---

### Libraries

| Current        | Target             | Type          | Count |
| -------------- | ------------------ | ------------- | ----- |
| `address from` | `address buyer`    | Parameter     | 2     |
| `address to`   | `address seller`   | Parameter     | 2     |
| Comments       | Update terminology | Documentation | ~5    |

**Total Library Changes**: ~10

---

## Implementation Order

### Step 1: Enums and Struct Fields (Foundation)

1. Rename enums: `SenderStatus` → `BuyerStatus`, `RecipientStatus` → `SellerStatus`
2. Rename struct fields: `from` → `buyer`, `to` → `seller`, `senderStatus` → `buyerStatus`, `recipientStatus` → `sellerStatus`
3. Compile and fix any immediate errors

### Step 2: Function Names

1. Rename `senderCancel()` → `buyerCancel()`
2. Rename `recipientCancel()` → `sellerCancel()`
3. Update all function calls

### Step 3: Errors

1. Rename error definitions
2. Update all error usages

### Step 4: References Throughout Codebase

1. Update all `et.from` → `et.buyer`
2. Update all `et.to` → `et.seller`
3. Update all `et.senderStatus` → `et.buyerStatus`
4. Update all `et.recipientStatus` → `et.sellerStatus`
5. Update enum usages: `SenderStatus.` → `BuyerStatus.`, `RecipientStatus.` → `SellerStatus.`

### Step 5: Events

1. Update event parameter names
2. Update event emissions

### Step 6: Function Parameters and Internal Variables

1. Update function signatures
2. Update internal variable names
3. Update comments

### Step 7: Libraries

1. Update library parameter names
2. Update comments

---

## Size Impact

**Total Size Impact**: **~0 bytes**

- Enum names: Don't affect bytecode
- Struct field names: Don't affect bytecode
- Function names: Don't affect bytecode (only selector)
- Error names: Don't affect bytecode
- Event parameter names: Don't affect ABI
- Variable names: Don't affect bytecode

**All changes are cosmetic/naming only** - no bytecode impact.

---

## Testing Requirements

### Unit Tests

- [ ] Test `buyerCancel()` function
- [ ] Test `sellerCancel()` function
- [ ] Test struct field access with new names
- [ ] Test enum usage with new names
- [ ] Test error messages with new names

### Integration Tests

- [ ] Verify escrow creation with buyer/seller
- [ ] Verify cancel flow with buyer/seller
- [ ] Verify dispute flow
- [ ] Verify event emissions

### Regression Tests

- [ ] All existing functionality works
- [ ] No breaking changes to logic
- [ ] Gas costs unchanged

---

## Breaking Changes

### Function Names

- ❌ `senderCancel()` → ✅ `buyerCancel()`
- ❌ `recipientCancel()` → ✅ `sellerCancel()`

### Struct Fields

- ❌ `from` → ✅ `buyer`
- ❌ `to` → ✅ `seller`
- ❌ `senderStatus` → ✅ `buyerStatus`
- ❌ `recipientStatus` → ✅ `sellerStatus`

### Enums

- ❌ `SenderStatus` → ✅ `BuyerStatus`
- ❌ `RecipientStatus` → ✅ `SellerStatus`

### Errors

- ❌ `NotSender` → ✅ `NotBuyer`
- ❌ `NotRecipient` → ✅ `NotSeller`
- ❌ `NotParticipant(..., sender, recipient)` → ✅ `NotParticipant(..., buyer, seller)`

### Impact

- **Testnet Only**: Base Sepolia
- **Single User**: Dev only
- **Action Required**: Update wallet app with new names

---

## Consistency Checklist

### ✅ Functions

- [ ] `buyerCancel()` - Buyer cancels escrow
- [ ] `sellerCancel()` - Seller cancels escrow
- [ ] `createEscrow(address seller, ...)` - Buyer creates escrow for seller
- [ ] `releaseEscrowTransfer()` - Buyer releases to seller
- [ ] `getEscrowParticipants()` returns `(buyer, seller)`

### ✅ Struct Fields

- [ ] `buyer` - Person paying
- [ ] `seller` - Person receiving
- [ ] `buyerStatus` - Buyer's status
- [ ] `sellerStatus` - Seller's status

### ✅ Enums

- [ ] `BuyerStatus` - Buyer status enum
- [ ] `SellerStatus` - Seller status enum

### ✅ Errors

- [ ] `NotBuyer` - Caller is not the buyer
- [ ] `NotSeller` - Caller is not the seller
- [ ] `NotParticipant(..., buyer, seller)` - Caller is not buyer or seller

### ✅ Events

- [ ] All events use `buyer` and `seller` parameter names
- [ ] Event emissions use `buyer` and `seller` variables

### ✅ Comments

- [ ] All comments use "buyer" and "seller"
- [ ] No references to "sender", "recipient", "payer", "payee"

---

## Code Examples

### Before (Inconsistent)

```solidity
struct EscrowTransfer {
  address from; // ❌
  address to; // ❌
  SenderStatus senderStatus; // ❌
  RecipientStatus recipientStatus; // ❌
}

function senderCancel(uint256 workflowId) public {
  if (et.from != _msgSender()) {
    revert NotSender(workflowId, _msgSender(), et.from);
  }
  et.senderStatus = SenderStatus.AGREE_TO_CANCEL;
}

event EscrowTransferCreated(
  uint256 indexed workflowId,
  address indexed from,
  address to,
  uint256 amount
);
```

### After (Consistent)

```solidity
struct EscrowTransfer {
  address buyer; // ✅
  address seller; // ✅
  BuyerStatus buyerStatus; // ✅
  SellerStatus sellerStatus; // ✅
}

function buyerCancel(uint256 workflowId) public {
  if (et.buyer != _msgSender()) {
    revert NotBuyer(workflowId, _msgSender(), et.buyer);
  }
  et.buyerStatus = BuyerStatus.AGREE_TO_CANCEL;
}

event EscrowTransferCreated(
  uint256 indexed workflowId,
  address indexed buyer,
  address seller,
  uint256 amount
);
```

---

## Implementation Complexity

### Low Complexity ✅

- Function renames (2 functions)
- Error renames (3 errors)
- Event parameter names (cosmetic)

### Medium Complexity ⚠️

- Struct field renames (~170 references)
- Enum renames (~20 references)
- Function parameter updates (~50 references)

### High Complexity ⚠️

- Systematic find/replace across entire codebase
- Need to be careful with:
  - Event emissions (must match event definitions)
  - Struct initializations (must match struct definition)
  - Error usages (must match error definitions)

---

## Risk Assessment

### Low Risk ✅

- Naming changes only (no logic changes)
- Testnet deployment (single user)
- Compiler will catch most errors

### Medium Risk ⚠️

- Many references to update (~250+)
- Easy to miss some references
- Need thorough testing

### Mitigation

- Use IDE find/replace with care
- Compile after each phase
- Run full test suite
- Code review

---

## Estimated Effort

### Phase 1 (Enums/Struct): 2-3 hours

- Rename definitions
- Update all references
- Compile and fix errors

### Phase 2 (Functions): 1 hour

- Rename functions
- Update calls

### Phase 3 (Errors): 1 hour

- Rename errors
- Update usages

### Phase 4 (Events): 1-2 hours

- Update definitions
- Update emissions

### Phase 5 (Parameters/Variables): 2-3 hours

- Update function signatures
- Update internal variables
- Update comments

### Phase 6 (Libraries): 0.5 hours

- Update library functions

### Testing: 2-3 hours

- Run test suite
- Fix any issues
- Verify functionality

**Total Estimated Time**: 9-13 hours

---

## Verification Checklist

After implementation, verify:

- [ ] All contracts compile successfully
- [ ] No linter errors
- [ ] All tests pass
- [ ] No references to "sender", "recipient", "from", "to" (except in library parameter names if needed)
- [ ] All functions use buyer/seller terminology
- [ ] All struct fields use buyer/seller terminology
- [ ] All enums use BuyerStatus/SellerStatus
- [ ] All errors use buyer/seller terminology
- [ ] All events use buyer/seller parameter names
- [ ] All comments use buyer/seller terminology
- [ ] Wallet app can be updated easily

---

## Complete Terminology Audit

### ✅ All Uses of "sender" / "Sender" (Must Change to "buyer" / "Buyer")

| Location                | Current                                                | Target                                               | Type            |
| ----------------------- | ------------------------------------------------------ | ---------------------------------------------------- | --------------- |
| BaseEscrow.sol:65       | `enum SenderStatus`                                    | `enum BuyerStatus`                                   | Enum definition |
| BaseEscrow.sol:87       | `SenderStatus senderStatus`                            | `BuyerStatus buyerStatus`                            | Struct field    |
| BaseEscrow.sol:489      | `function senderCancel()`                              | `function buyerCancel()`                             | Function        |
| BaseEscrow.sol:39       | `error NotParticipant(..., sender, ...)`               | `error NotParticipant(..., buyer, ...)`              | Error param     |
| BaseEscrow.sol:42       | `error NotSender(...)`                                 | `error NotBuyer(...)`                                | Error name      |
| BaseEscrow.sol:428      | `revert NotParticipant(..., et.from, ...)`             | `revert NotParticipant(..., et.buyer, ...)`          | Error usage     |
| BaseEscrow.sol:493      | `revert NotSender(...)`                                | `revert NotBuyer(...)`                               | Error usage     |
| BaseEscrow.sol:942      | `revert NotParticipant(..., et.from, ...)`             | `revert NotParticipant(..., et.buyer, ...)`          | Error usage     |
| BaseEscrow.sol:1061     | `revert NotParticipant(..., et.from, ...)`             | `revert NotParticipant(..., et.buyer, ...)`          | Error usage     |
| BaseEscrow.sol:1165     | `revert NotParticipant(..., et.from, ...)`             | `revert NotParticipant(..., et.buyer, ...)`          | Error usage     |
| BaseEscrow.sol:1234     | `revert NotParticipant(..., et.from, ...)`             | `revert NotParticipant(..., et.buyer, ...)`          | Error usage     |
| BaseEscrow.sol:1621     | `revert NotParticipant(..., et.from, ...)`             | `revert NotParticipant(..., et.buyer, ...)`          | Error usage     |
| BaseEscrow.sol:1802     | `revert NotSender(...)`                                | `revert NotBuyer(...)`                               | Error usage     |
| BaseEscrow.sol:499      | `et.senderStatus = SenderStatus.AGREE_TO_CANCEL`       | `et.buyerStatus = BuyerStatus.AGREE_TO_CANCEL`       | Enum usage      |
| BaseEscrow.sol:474      | `if (et.senderStatus == SenderStatus.AGREE_TO_CANCEL)` | `if (et.buyerStatus == BuyerStatus.AGREE_TO_CANCEL)` | Enum usage      |
| BaseEscrow.sol:936      | `et.senderStatus = SenderStatus.RAISE_DISPUTE`         | `et.buyerStatus = BuyerStatus.RAISE_DISPUTE`         | Enum usage      |
| BaseEscrow.sol:1837     | `et.senderStatus = SenderStatus.AGREE_TO_CANCEL`       | `et.buyerStatus = BuyerStatus.AGREE_TO_CANCEL`       | Enum usage      |
| BaseEscrow.sol:1842     | `if (et.senderStatus == SenderStatus.AGREE_TO_CANCEL`  | `if (et.buyerStatus == BuyerStatus.AGREE_TO_CANCEL`  | Enum usage      |
| EscrowVault.sol:151     | `senderStatus: SenderStatus.NONE`                      | `buyerStatus: BuyerStatus.NONE`                      | Struct init     |
| EscrowableERC20.sol:148 | `senderStatus: SenderStatus.NONE`                      | `buyerStatus: BuyerStatus.NONE`                      | Struct init     |
| Comments                | "sender", "Only sender can"                            | "buyer", "Only buyer can"                            | Documentation   |

**Total "sender" references**: ~25+

---

### ✅ All Uses of "recipient" / "Recipient" (Must Change to "seller" / "Seller")

| Location                   | Current                                                      | Target                                                 | Type            |
| -------------------------- | ------------------------------------------------------------ | ------------------------------------------------------ | --------------- |
| BaseEscrow.sol:71          | `enum RecipientStatus`                                       | `enum SellerStatus`                                    | Enum definition |
| BaseEscrow.sol:88          | `RecipientStatus recipientStatus`                            | `SellerStatus sellerStatus`                            | Struct field    |
| BaseEscrow.sol:448         | `function recipientCancel()`                                 | `function sellerCancel()`                              | Function        |
| BaseEscrow.sol:39          | `error NotParticipant(..., recipient)`                       | `error NotParticipant(..., seller)`                    | Error param     |
| BaseEscrow.sol:43          | `error NotRecipient(...)`                                    | `error NotSeller(...)`                                 | Error name      |
| BaseEscrow.sol:428         | `revert NotParticipant(..., et.to)`                          | `revert NotParticipant(..., et.seller)`                | Error usage     |
| BaseEscrow.sol:452         | `revert NotRecipient(...)`                                   | `revert NotSeller(...)`                                | Error usage     |
| BaseEscrow.sol:942         | `revert NotParticipant(..., et.to)`                          | `revert NotParticipant(..., et.seller)`                | Error usage     |
| BaseEscrow.sol:1061        | `revert NotParticipant(..., et.to)`                          | `revert NotParticipant(..., et.seller)`                | Error usage     |
| BaseEscrow.sol:1165        | `revert NotParticipant(..., et.to)`                          | `revert NotParticipant(..., et.seller)`                | Error usage     |
| BaseEscrow.sol:1234        | `revert NotParticipant(..., et.to)`                          | `revert NotParticipant(..., et.seller)`                | Error usage     |
| BaseEscrow.sol:1621        | `revert NotParticipant(..., et.to)`                          | `revert NotParticipant(..., et.seller)`                | Error usage     |
| BaseEscrow.sol:469         | `et.recipientStatus = RecipientStatus.AGREE_TO_CANCEL`       | `et.sellerStatus = SellerStatus.AGREE_TO_CANCEL`       | Enum usage      |
| BaseEscrow.sol:474         | `if (et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL)` | `if (et.sellerStatus == SellerStatus.AGREE_TO_CANCEL)` | Enum usage      |
| BaseEscrow.sol:504         | `if (et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL)` | `if (et.sellerStatus == SellerStatus.AGREE_TO_CANCEL)` | Enum usage      |
| BaseEscrow.sol:939         | `et.recipientStatus = RecipientStatus.RAISE_DISPUTE`         | `et.sellerStatus = SellerStatus.RAISE_DISPUTE`         | Enum usage      |
| BaseEscrow.sol:1836        | `if (et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL)` | `if (et.sellerStatus == SellerStatus.AGREE_TO_CANCEL)` | Enum usage      |
| BaseEscrow.sol:1843        | `if (et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL)` | `if (et.sellerStatus == SellerStatus.AGREE_TO_CANCEL)` | Enum usage      |
| EscrowVault.sol:152        | `recipientStatus: RecipientStatus.NONE`                      | `sellerStatus: SellerStatus.NONE`                      | Struct init     |
| EscrowableERC20.sol:149    | `recipientStatus: RecipientStatus.NONE`                      | `sellerStatus: SellerStatus.NONE`                      | Struct init     |
| Comments                   | "recipient", "to recipient"                                  | "seller", "to seller"                                  | Documentation   |
| DefaultReleaseStrategy.sol | "returns recipient"                                          | "returns seller"                                       | Comment         |

**Total "recipient" references**: ~25+

---

### ✅ All Uses of "from" (Must Change to "buyer")

| Location                | Current                                              | Target                                               | Type                        |
| ----------------------- | ---------------------------------------------------- | ---------------------------------------------------- | --------------------------- |
| BaseEscrow.sol:83       | `address from`                                       | `address buyer`                                      | Struct field                |
| BaseEscrow.sol:258      | `if (et.from != _msgSender())`                       | `if (et.buyer != _msgSender())`                      | Validation                  |
| BaseEscrow.sol:260      | `revert NotSender(..., et.from)`                     | `revert NotBuyer(..., et.buyer)`                     | Error usage                 |
| BaseEscrow.sol:428      | `revert NotParticipant(..., et.from, ...)`           | `revert NotParticipant(..., et.buyer, ...)`          | Error usage                 |
| BaseEscrow.sol:492      | `if (et.from != _msgSender())`                       | `if (et.buyer != _msgSender())`                      | Validation                  |
| BaseEscrow.sol:493      | `revert NotSender(..., et.from)`                     | `revert NotBuyer(..., et.buyer)`                     | Error usage                 |
| BaseEscrow.sol:628      | `address from = et.from`                             | `address buyer = et.buyer`                           | Variable                    |
| BaseEscrow.sol:634      | `address from = et.from`                             | `address buyer = et.buyer`                           | Variable                    |
| BaseEscrow.sol:664      | `address from = et.from`                             | `address buyer = et.buyer`                           | Variable                    |
| BaseEscrow.sol:722      | `address from = et.from`                             | `address buyer = et.buyer`                           | Variable                    |
| BaseEscrow.sol:793      | `address refundTo = et.from`                         | `address refundTo = et.buyer`                        | Variable                    |
| BaseEscrow.sol:854      | `et.from`                                            | `et.buyer`                                           | Encoding                    |
| BaseEscrow.sol:905      | `address from`                                       | `address buyer`                                      | Parameter                   |
| BaseEscrow.sol:942      | `revert NotParticipant(..., et.from, ...)`           | `revert NotParticipant(..., et.buyer, ...)`          | Error usage                 |
| BaseEscrow.sol:1061     | `revert NotParticipant(..., et.from, ...)`           | `revert NotParticipant(..., et.buyer, ...)`          | Error usage                 |
| BaseEscrow.sol:1075     | `et.from`                                            | `et.buyer`                                           | Encoding                    |
| BaseEscrow.sol:1165     | `revert NotParticipant(..., et.from, ...)`           | `revert NotParticipant(..., et.buyer, ...)`          | Error usage                 |
| BaseEscrow.sol:1234     | `revert NotParticipant(..., et.from, ...)`           | `revert NotParticipant(..., et.buyer, ...)`          | Error usage                 |
| BaseEscrow.sol:1324     | `address from = et.from`                             | `address buyer = et.buyer`                           | Variable                    |
| BaseEscrow.sol:1348     | `_transferTokens(token, from, amount)`               | `_transferTokens(token, buyer, amount)`              | Function call               |
| BaseEscrow.sol:1349     | `_emitEscrowTransferCancelled(..., from, ...)`       | `_emitEscrowTransferCancelled(..., buyer, ...)`      | Event                       |
| BaseEscrow.sol:1350     | `address from = et.from`                             | `address buyer = et.buyer`                           | Variable                    |
| BaseEscrow.sol:1621     | `revert NotParticipant(..., et.from, ...)`           | `revert NotParticipant(..., et.buyer, ...)`          | Error usage                 |
| BaseEscrow.sol:1765     | `returns (address from, address to)`                 | `returns (address buyer, address seller)`            | Return values               |
| BaseEscrow.sol:1768     | `return (et.from, et.to)`                            | `return (et.buyer, et.seller)`                       | Return statement            |
| BaseEscrow.sol:1802     | `revert NotSender(..., et.from)`                     | `revert NotBuyer(..., et.buyer)`                     | Error usage                 |
| EscrowVault.sol:147     | `from: _msgSender()`                                 | `buyer: _msgSender()`                                | Struct init                 |
| EscrowVault.sol:197     | `emit EscrowTransferCreated(..., _msgSender(), ...)` | `emit EscrowTransferCreated(..., _msgSender(), ...)` | Event (buyer is msg.sender) |
| EscrowableERC20.sol:144 | `from: _msgSender()`                                 | `buyer: _msgSender()`                                | Struct init                 |
| EscrowableERC20.sol:200 | `emit EscrowTransferCreated(..., _msgSender(), ...)` | `emit EscrowTransferCreated(..., _msgSender(), ...)` | Event (buyer is msg.sender) |
| Events                  | `address indexed from`                               | `address indexed buyer`                              | Event params                |
| Library                 | `address from`                                       | `address buyer`                                      | Parameter                   |

**Total "from" references**: ~80+

---

### ✅ All Uses of "to" (Must Change to "seller")

| Location                | Current                                        | Target                                          | Type                                |
| ----------------------- | ---------------------------------------------- | ----------------------------------------------- | ----------------------------------- |
| BaseEscrow.sol:82       | `address to`                                   | `address seller`                                | Struct field                        |
| BaseEscrow.sol:258      | `if (et.to != _msgSender())`                   | `if (et.seller != _msgSender())`                | Validation (in release)             |
| BaseEscrow.sol:428      | `revert NotParticipant(..., et.to)`            | `revert NotParticipant(..., et.seller)`         | Error usage                         |
| BaseEscrow.sol:452      | `revert NotRecipient(..., et.to)`              | `revert NotSeller(..., et.seller)`              | Error usage                         |
| BaseEscrow.sol:664      | `address to = et.to`                           | `address seller = et.seller`                    | Variable                            |
| BaseEscrow.sol:688      | `_transferTokens(token, to, amount)`           | `_transferTokens(token, seller, amount)`        | Function call                       |
| BaseEscrow.sol:720      | `address releaseTo = et.to`                    | `address releaseTo = et.seller`                 | Variable                            |
| BaseEscrow.sol:758      | `_transferTokens(token, releaseTo, amount)`    | `_transferTokens(token, releaseTo, amount)`     | Function call (releaseTo is seller) |
| BaseEscrow.sol:794      | `address to = et.to`                           | `address seller = et.seller`                    | Variable                            |
| BaseEscrow.sol:833      | `_transferTokens(token, refundTo, amount)`     | `_transferTokens(token, refundTo, amount)`      | Function call (refundTo is buyer)   |
| BaseEscrow.sol:855      | `et.to`                                        | `et.seller`                                     | Encoding                            |
| BaseEscrow.sol:905      | `address to`                                   | `address seller`                                | Parameter                           |
| BaseEscrow.sol:942      | `revert NotParticipant(..., et.to)`            | `revert NotParticipant(..., et.seller)`         | Error usage                         |
| BaseEscrow.sol:1061     | `revert NotParticipant(..., et.to)`            | `revert NotParticipant(..., et.seller)`         | Error usage                         |
| BaseEscrow.sol:1075     | `et.to`                                        | `et.seller`                                     | Encoding                            |
| BaseEscrow.sol:1165     | `revert NotParticipant(..., et.to)`            | `revert NotParticipant(..., et.seller)`         | Error usage                         |
| BaseEscrow.sol:1234     | `revert NotParticipant(..., et.to)`            | `revert NotParticipant(..., et.seller)`         | Error usage                         |
| BaseEscrow.sol:1367     | `address to = et.to`                           | `address seller = et.seller`                    | Variable                            |
| BaseEscrow.sol:1399     | `_transferTokens(token, to, amount)`           | `_transferTokens(token, seller, amount)`        | Function call                       |
| BaseEscrow.sol:1400     | `_emitEscrowTransferReleased(..., to, ...)`    | `_emitEscrowTransferReleased(..., seller, ...)` | Event                               |
| BaseEscrow.sol:1621     | `revert NotParticipant(..., et.to)`            | `revert NotParticipant(..., et.seller)`         | Error usage                         |
| BaseEscrow.sol:1765     | `returns (address from, address to)`           | `returns (address buyer, address seller)`       | Return values                       |
| BaseEscrow.sol:1768     | `return (et.from, et.to)`                      | `return (et.buyer, et.seller)`                  | Return statement                    |
| EscrowVault.sol:146     | `to: seller`                                   | `seller: seller`                                | Struct init                         |
| EscrowVault.sol:197     | `emit EscrowTransferCreated(..., seller, ...)` | `emit EscrowTransferCreated(..., seller, ...)`  | Event (already correct)             |
| EscrowableERC20.sol:143 | `to: seller`                                   | `seller: seller`                                | Struct init                         |
| EscrowableERC20.sol:200 | `emit EscrowTransferCreated(..., seller, ...)` | `emit EscrowTransferCreated(..., seller, ...)`  | Event (already correct)             |
| Events                  | `address indexed to`                           | `address indexed seller`                        | Event params                        |
| Library                 | `address to`                                   | `address seller`                                | Parameter                           |

**Total "to" references**: ~80+

---

### ❌ No Changes Needed (Keep As-Is)

These uses are **NOT** related to buyer/seller terminology:

1. **`_msgSender()`** - Standard OpenZeppelin pattern (keep as-is)
2. **`from`/`to` in ERC20 transfers** - Standard ERC20 pattern (keep as-is)
   - `_transfer(address from, address to, uint256 amount)`
   - `safeTransferFrom(address from, address to, uint256 amount)`
3. **Event `fromLevel`/`toLevel`** in `DisputeEscalated` - Refers to escalation levels, not parties
   - `event DisputeEscalated(..., uint8 fromLevel, uint8 toLevel, ...)`
4. **`recipient` in yield distribution** - Refers to yield recipients, not escrow parties
   - `event YieldDistributed(..., address indexed recipient, ...)`
   - `address[] recipients` in YieldDistribution struct
5. **`from` in comments about transfers** - Refers to transfer source, not escrow party
   - "Transfer tokens from sender to this contract" (keep as-is)

---

## Summary

**Total Changes Required**: ~250+ references across:

- Struct fields: 4 fields
- Enums: 2 enums
- Functions: 2 functions
- Errors: 3 errors
- Events: ~15 events (parameter names)
- Variables: ~160 variable references
- Comments: ~40 comment updates

**No Changes Needed**: ~5 patterns (standard Solidity/ERC20 patterns)

---

## Notes

---

## Notes

- **Size Impact**: Zero bytes (all naming changes)
- **Breaking Changes**: Yes, but acceptable for testnet
- **Complexity**: Medium (many references, but straightforward)
- **Risk**: Low (naming only, compiler catches errors)
- **Timeline**: Can be done in one focused session (9-13 hours)

---

## Next Steps

1. **Review this plan** - Confirm approach
2. **Create implementation branch** - `feature/buyer-seller-consistency`
3. **Implement Phase 1** - Enums and struct fields
4. **Compile and fix** - Address any errors
5. **Continue with remaining phases** - Systematic implementation
6. **Test thoroughly** - Full test suite
7. **Update wallet app** - With new terminology
8. **Deploy to testnet** - Verify in production-like environment

---

**Status**: Ready for Implementation  
**Priority**: HIGH (completes consistency improvements)
