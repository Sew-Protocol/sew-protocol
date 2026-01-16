# Appeal Bond Token Whitelist Implementation Plan

## Overview

Currently, appeal bonds accept a single token configured via `EscalationCostConfig.bondToken`. This plan adds support for a governance-controlled whitelist of accepted tokens, with a default of USD stablecoin.

## Current State

- **Default**: `address(0)` (ETH) in `DecentralizedResolutionModule` constructor
- **Configuration**: Single token via `EscalationCostConfig.bondToken`
- **Change Process**: Slow lane governance (7-day delay)
- **Validation**: None - accepts any token address

## Target State

- **Default**: USD stablecoin (e.g., USDC on Base, USDC.e on Base)
- **Configuration**: Whitelist of accepted tokens (governance-controlled)
- **Change Process**: Slow lane governance for adding/removing tokens
- **Validation**: Bonds must use tokens from whitelist

## Implementation Plan

### Phase 1: Update Default Token

**Files to Modify**:
- `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`

**Changes**:
1. Add constant for default stablecoin address (or constructor parameter)
2. Update constructor to set default `bondToken` to stablecoin instead of ETH
3. Add comment noting default will be set at deployment time

**Code Changes**:
```solidity
// In DecentralizedResolutionModule.sol constructor
// Before:
bondToken: address(0)  // ETH

// After:
bondToken: defaultStablecoinAddress  // USD stablecoin (set at deployment)
```

**Considerations**:
- Default stablecoin address should be passed as constructor parameter or set via governance after deployment
- Different chains may use different stablecoins (USDC on Base, USDC.e on Base, USDC on Ethereum)
- Consider making it a deployment-time configuration

### Phase 2: Add Token Whitelist

**New State Variables**:
```solidity
// Whitelist of accepted bond tokens
mapping(address => bool) public acceptedBondTokens;
address[] public acceptedBondTokensList;  // For enumeration
address public defaultBondToken;  // Default token for bonds
```

**New Functions**:
```solidity
/**
 * @notice Add token to accepted bond tokens whitelist
 * @param token Token address to add
 * @dev Requires ROLE_TIMELOCK, slow lane governance
 */
function queueAddAcceptedBondToken(address token) external onlyRole(ROLE_TIMELOCK);

/**
 * @notice Remove token from accepted bond tokens whitelist
 * @param token Token address to remove
 * @dev Requires ROLE_TIMELOCK, slow lane governance
 */
function queueRemoveAcceptedBondToken(address token) external onlyRole(ROLE_TIMELOCK);

/**
 * @notice Activate queued token addition/removal
 * @dev Requires ROLE_TIMELOCK, after timelock delay
 */
function activateBondTokenWhitelistChange() external onlyRole(ROLE_TIMELOCK);

/**
 * @notice Check if token is accepted for bonds
 * @param token Token address to check
 * @return True if token is accepted
 */
function isAcceptedBondToken(address token) external view returns (bool);

/**
 * @notice Set default bond token
 * @param token Token address (must be in whitelist)
 * @dev Requires ROLE_TIMELOCK, slow lane governance
 */
function queueSetDefaultBondToken(address token) external onlyRole(ROLE_TIMELOCK);
```

**Pending State Structure**:
```solidity
struct PendingBondTokenChange {
    address token;
    bool isAdd;  // true = add, false = remove
    uint64 eta;
    bool exists;
}
PendingBondTokenChange private _pendingBondTokenChange;

struct PendingDefaultBondToken {
    address token;
    uint64 eta;
    bool exists;
}
PendingDefaultBondToken private _pendingDefaultBondToken;
```

### Phase 3: Update Bond Validation

**Files to Modify**:
- `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- `contracts/core/BaseEscrow.sol`

**Changes**:
1. Validate bond token in `getRequiredAppealBond()` - ensure it's in whitelist
2. Validate bond token when recording bond in `BaseEscrow.escalateDispute()`
3. Add validation in `ResolverIncentiveModuleV2.recordAppealBond()`

**Validation Logic**:
```solidity
function getRequiredAppealBond(
    uint256 workflowId,
    uint8 currentLevel,
    bytes calldata escrowData
) external view override returns (uint256 bondAmount, address bondToken) {
    if (!escalationCostConfig.enabled) {
        return (0, address(0));
    }
    
    // Calculate bond amount
    uint8 escalationCount = currentLevel;
    uint256 bondAmount = EscalationCostLibrary.calculateEscalationCost(
        escalationCount,
        escalationCostConfig
    );
    
    // Use default bond token if configured, otherwise use from config
    address token = defaultBondToken != address(0) 
        ? defaultBondToken 
        : escalationCostConfig.bondToken;
    
    // Validate token is in whitelist
    require(acceptedBondTokens[token] || token == address(0), "Token not accepted for bonds");
    
    return (bondAmount, token);
}
```

### Phase 4: Update EscalationCostConfig

**Decision**: Keep `bondToken` in `EscalationCostConfig` for backward compatibility, but:
- If `bondToken` is set, it must be in whitelist
- If `bondToken` is `address(0)`, use `defaultBondToken`
- Add validation in `queueEscalationCostConfig()`

**Changes**:
```solidity
function queueEscalationCostConfig(
    EscalationCostConfig memory config
) external onlyRole(ROLE_TIMELOCK) {
    require(config.baseCost > 0 || !config.enabled, 'Base cost must be > 0 if enabled');
    
    // Validate bond token if specified
    if (config.bondToken != address(0)) {
        require(
            acceptedBondTokens[config.bondToken] || config.bondToken == address(0),
            "Bond token not in whitelist"
        );
    }
    
    _pendingEscalationCostConfig = PendingEscalationCostConfig({
        config: config,
        eta: uint64(block.timestamp + SLOW_DELAY),
        exists: true
    });
    
    emit EscalationCostConfigQueued(config, _pendingEscalationCostConfig.eta);
}
```

### Phase 5: Events

**New Events**:
```solidity
event AcceptedBondTokenQueued(address indexed token, bool isAdd, uint64 eta);
event AcceptedBondTokenChanged(address indexed token, bool isAdd);
event DefaultBondTokenQueued(address indexed token, uint64 eta);
event DefaultBondTokenChanged(address indexed oldToken, address indexed newToken);
```

### Phase 6: Initialization

**Constructor Changes**:
```solidity
constructor(address initialOwner) {
    // ... existing code ...
    
    // Initialize with default stablecoin (passed as parameter or set later)
    // For now, keep ETH as default but add comment
    escalationCostConfig = EscalationCostConfig({
        enabled: true,
        curveType: CostCurveType.QUADRATIC,
        baseCost: 0.01 ether,
        stepSize: 0.01 ether,
        multiplier: 0,
        bondToken: address(0)  // Will be set to stablecoin at deployment
    });
    
    // Initialize whitelist (empty initially, populated via governance)
    // Or add constructor parameter for initial stablecoin
}
```

**Alternative**: Add constructor parameter for initial stablecoin:
```solidity
constructor(address initialOwner, address initialStablecoin) {
    // ... existing code ...
    
    // Add initial stablecoin to whitelist
    if (initialStablecoin != address(0)) {
        acceptedBondTokens[initialStablecoin] = true;
        acceptedBondTokensList.push(initialStablecoin);
        defaultBondToken = initialStablecoin;
        
        escalationCostConfig.bondToken = initialStablecoin;
    }
}
```

## Migration Strategy

1. **Deploy with ETH as default** (backward compatible)
2. **Add stablecoin to whitelist** via governance
3. **Set stablecoin as default** via governance
4. **Update EscalationCostConfig** to use stablecoin (optional, since default will be used)

## Testing Requirements

1. **Unit Tests**:
   - Test whitelist add/remove
   - Test default token selection
   - Test validation in `getRequiredAppealBond()`
   - Test validation in `recordAppealBond()`

2. **Integration Tests**:
   - Test escalation with whitelisted token
   - Test escalation with non-whitelisted token (should fail)
   - Test default token fallback
   - Test governance flow (queue → activate)

3. **Edge Cases**:
   - Removing default token (should require setting new default first)
   - Empty whitelist (should allow ETH as fallback)
   - Token not in whitelist but in EscalationCostConfig (should fail validation)

## Documentation Updates

1. Update `CURRENCY_MANAGEMENT.md` with whitelist information
2. Update `DecentralizedResolutionModule` NatSpec comments
3. Add governance guide for managing bond token whitelist
4. Update deployment guide with stablecoin configuration

## Security Considerations

1. **Reentrancy**: Whitelist changes use slow lane, already protected
2. **Access Control**: All changes require `ROLE_TIMELOCK`
3. **Validation**: Bonds validated at multiple points (getRequiredAppealBond, recordAppealBond)
4. **Default Token**: Should always be set to prevent accidental ETH usage
5. **Empty Whitelist**: Consider allowing ETH as fallback if whitelist is empty

## Open Questions

1. **Should we allow ETH as fallback** if whitelist is empty?
2. **Should we allow removing the default token** without setting a new one first?
3. **Should we support multiple default tokens** (e.g., USDC and USDC.e)?
4. **Should we add token metadata** (name, symbol, decimals) for better UX?

## Implementation Order

1. ✅ Update default token documentation
2. ⏳ Add whitelist state variables and basic functions
3. ⏳ Add validation in bond-related functions
4. ⏳ Add governance functions (queue/activate)
5. ⏳ Add tests
6. ⏳ Update documentation
