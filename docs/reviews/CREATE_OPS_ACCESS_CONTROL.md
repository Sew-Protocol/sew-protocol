# CreateOps Access Control Review

**Date**: 2026-01-27  
**Contract**: `contracts/CreateOps.sol`  
**Function**: `computeEscrowCreation`

## Current State

**Function Visibility**: `external view`  
**Access Control**: ❌ **NONE** - Anyone can call this function

```solidity
function computeEscrowCreation(...) external view returns (CreateResult memory result) {
    // No access control checks
}
```

## Security Analysis

### Current Risks

1. **DoS via Spam Calls**
   - Anyone can call `computeEscrowCreation` repeatedly
   - Expensive operations (validation, module queries) consume gas
   - Could be used to spam the network

2. **Information Leakage**
   - Attackers can probe validation logic
   - Can test different inputs to understand fee calculations
   - Can front-run by checking if validation will pass

3. **Validation Logic Testing**
   - Attackers can test edge cases without creating escrows
   - Can discover validation bypasses
   - Can understand internal fee/resolver logic

4. **Inconsistent with Other Ops Contracts**
   - `DisputeOps` and `SettlementOps` also have no access control
   - But `KlerosArbitrableProxy` uses `onlyRole(ROLE_ESCROW_CONTRACT)`
   - `YieldOps` has some internal checks

### Why Restrict?

**Arguments FOR Restriction:**
1. ✅ **Security Best Practice**: Ops contracts should only be called by escrow contracts
2. ✅ **DoS Prevention**: Prevents spam calls
3. ✅ **Information Hiding**: Prevents probing of validation logic
4. ✅ **Consistency**: Aligns with `ROLE_ESCROW_CONTRACT` pattern used elsewhere
5. ✅ **Clear Intent**: Makes it explicit that this is an internal computation function

**Arguments AGAINST Restriction:**
1. ❌ **View Function**: No state changes, so "harmless"
2. ❌ **Size Impact**: Adding access control adds bytecode
3. ❌ **Other Ops Don't Have It**: `DisputeOps` and `SettlementOps` are also unrestricted

**Verdict**: ✅ **SHOULD BE RESTRICTED** - Security best practice outweighs size concerns

---

## Recommended Implementation

### Option 1: Simple Caller Check (Recommended for Size)

```solidity
contract CreateOps {
    address public immutable escrowContract;
    
    constructor(address _escrowContract) {
        escrowContract = _escrowContract;
    }
    
    modifier onlyEscrowContract() {
        if (msg.sender != escrowContract) revert OnlyEscrowContract(msg.sender);
        _;
    }
    
    function computeEscrowCreation(...) 
        external 
        view 
        onlyEscrowContract 
        returns (CreateResult memory result) 
    {
        // ... existing code ...
    }
}
```

**Pros:**
- Minimal bytecode (immutable + modifier)
- Simple and clear
- No AccessControl dependency

**Cons:**
- Only supports one escrow contract (EscrowVault OR EscrowableERC20, not both)
- Would need separate CreateOps instance per escrow type

### Option 2: AccessControl with ROLE_ESCROW_CONTRACT (More Flexible)

```solidity
import '@openzeppelin/contracts/access/AccessControl.sol';

contract CreateOps is AccessControl {
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');
    
    constructor(address initialOwner) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }
    
    function registerEscrowContract(address escrow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(ROLE_ESCROW_CONTRACT, escrow);
    }
    
    function computeEscrowCreation(...) 
        external 
        view 
        onlyRole(ROLE_ESCROW_CONTRACT) 
        returns (CreateResult memory result) 
    {
        // ... existing code ...
    }
}
```

**Pros:**
- Supports multiple escrow contracts (EscrowVault + EscrowableERC20)
- Flexible - can add/remove escrow contracts
- Consistent with `KlerosArbitrableProxy` pattern
- Admin can manage escrow contracts

**Cons:**
- More bytecode (AccessControl overhead)
- Requires deployment script to register escrow contracts
- More complex

### Option 3: Whitelist Mapping (Middle Ground)

```solidity
contract CreateOps {
    mapping(address => bool) public authorizedEscrowContracts;
    
    modifier onlyAuthorizedEscrow() {
        if (!authorizedEscrowContracts[msg.sender]) revert UnauthorizedEscrowContract(msg.sender);
        _;
    }
    
    function setAuthorizedEscrowContract(address escrow, bool authorized) external {
        // Only deployer/admin can set (would need access control)
        authorizedEscrowContracts[escrow] = authorized;
    }
    
    function computeEscrowCreation(...) 
        external 
        view 
        onlyAuthorizedEscrow 
        returns (CreateResult memory result) 
    {
        // ... existing code ...
    }
}
```

**Pros:**
- Supports multiple escrow contracts
- Simpler than AccessControl
- Can be set at deployment

**Cons:**
- Still needs access control for setter
- Mapping adds storage slot

---

## Comparison with Other Ops Contracts

| Contract | Access Control | Pattern |
|----------|---------------|---------|
| `CreateOps` | ❌ None | `external view` |
| `DisputeOps` | ❌ None | `external` |
| `SettlementOps` | ❌ None | `external view` |
| `YieldOps` | ✅ Partial | `AccessControl` for admin, internal checks |
| `KlerosArbitrableProxy` | ✅ Yes | `onlyRole(ROLE_ESCROW_CONTRACT)` |

**Observation**: All ops contracts should have access control, but currently only `YieldOps` and `KlerosArbitrableProxy` do.

---

## Recommendation

**Implement Option 2** (AccessControl with ROLE_ESCROW_CONTRACT):

1. **Consistency**: Matches `KlerosArbitrableProxy` pattern
2. **Flexibility**: Supports both EscrowVault and EscrowableERC20
3. **Future-Proof**: Can add more escrow contract types later
4. **Security**: Proper access control is worth the bytecode cost

**Size Impact**: ~500-800 bytes (AccessControl + modifier + registration function)

**Alternative if Size is Critical**: Use Option 1 (immutable caller check) if only EscrowVault needs it, or deploy separate CreateOps instances.

---

## Implementation Steps

1. Add `AccessControl` import and inheritance
2. Add `ROLE_ESCROW_CONTRACT` constant
3. Add constructor with initial owner
4. Add `registerEscrowContract()` function
5. Add `onlyRole(ROLE_ESCROW_CONTRACT)` modifier to `computeEscrowCreation`
6. Update deployment scripts to register EscrowVault and EscrowableERC20
7. Add error `UnauthorizedEscrowContract(address caller)`

---

## Security Benefits

✅ Prevents DoS via spam calls  
✅ Prevents validation logic probing  
✅ Prevents information leakage  
✅ Makes function intent explicit  
✅ Aligns with security best practices  
✅ Consistent with other access-controlled contracts
