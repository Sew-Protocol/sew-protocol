# Currency Management in Escrow System

This document provides a comprehensive overview of all currency choices in the escrow system, their defaults, how they're changed, and any restrictions.

## Currency Choice Overview

The escrow system involves four distinct currency choices:

1. **Escrow Amount Currency** - The token used for the actual escrow transfer
2. **Escrow Fee Currency** - The currency in which fees are paid
3. **Appeal Bond Currency** - The currency required for appeal bonds
4. **Resolver Fee Payment Currency** - The currency in which resolvers are paid for work (fee-based)
5. **Resolver Staking Currency** - The currency in which resolvers stake (capital at risk)
6. **Slashing Currency** - The currency that gets slashed (same as staked)

## Currency Choice Table

| Currency Type | Accepted | Default | How Changed | What Can Change | Restrictions |
|--------------|----------|---------|-------------|-----------------|--------------|
| **Escrow Amount** | Any ERC20 or ETH | None (user choice) | User selects at creation | N/A (user choice) | Must be valid ERC20 or ETH |
| **Escrow Fee** | Same as escrow amount | Same as escrow amount | N/A (enforced) | N/A | **RESTRICTION: Fees are always paid in the same token as the escrow amount** |
| **Appeal Bond** | Single token (configurable) | `address(0)` (ETH) → **Will change to USD stablecoin** | `queueEscalationCostConfig()` → `activateEscalationCostConfig()` (Slow lane, 7 days) | `bondToken` field in `EscalationCostConfig` | Currently single token only. **TODO: Add list of accepted tokens** |
| **Resolver Fee Payments** | Same as escrow fee | Same as escrow fee | N/A (enforced) | N/A | **RESTRICTION: Fee-based payments are always in the same token as the escrow fee (which matches escrow amount)** |
| **Resolver Staking** | USDC (80%) + SEW (20%) | Fixed mix | Governance (staking module) | Staking token addresses | **NOTE: Staking is capital at risk, not a payment mechanism. Separate from fee payments.** |
| **Slashing Penalties** | Same as staked tokens | USDC + SEW | Automatic (on poor performance) | N/A | **NOTE: Slashing reduces staked amounts. Separate from fee payments.** |

## Detailed Analysis

### 1. Escrow Amount Currency

**Location**: `BaseEscrow.createEscrow(address token, ...)`

- **Accepted**: Any ERC20 token address or `address(0)` for native ETH
- **Default**: None - user must specify
- **How Changed**: User selects when creating escrow
- **Restrictions**: 
  - Token must be a valid ERC20 contract (or ETH)
  - No whitelist/blacklist currently enforced

**Code References**:
- `BaseEscrow.sol:471-497` - Escrow creation
- `EscrowVault.sol:71-89` - Public createEscrow functions

### 2. Escrow Fee Currency

**Location**: `BaseEscrow._recordFee()` → `EscrowVault._recordFee()`

- **Accepted**: Same token as escrow amount
- **Default**: Automatically matches escrow amount token
- **How Changed**: Cannot be changed independently
- **Restrictions**: 
  - **CRITICAL**: Fees are ALWAYS paid in the same token as the escrow amount
  - This is enforced by the code flow: fee is calculated as percentage of escrow amount, then recorded in same token

**Code References**:
- `BaseEscrow.sol:476` - Fee calculation: `uint256 fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;`
- `BaseEscrow.sol:739-743` - Fee recording uses same token as escrow
- `EscrowVault.sol:103-105` - `_recordFee(address t, uint256 a)` tracks fees per token

**Implementation Details**:
```solidity
// Fee is always calculated from escrow amount
uint256 fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;
uint256 amountAfterFee = amount - fee;

// Fee is recorded in same token
_recordFee(token, fee);  // token is the escrow token
```

### 3. Appeal Bond Currency

**Location**: `DecentralizedResolutionModule.escalationCostConfig.bondToken`

- **Accepted**: Currently single token (ETH by default)
- **Default**: `address(0)` (ETH) → **PLANNED: USD stablecoin (e.g., USDC)**
- **How Changed**: 
  - Governance-controlled via `queueEscalationCostConfig()` → `activateEscalationCostConfig()`
  - Requires `ROLE_TIMELOCK`
  - Slow lane governance (7-day delay)
- **What Can Change**: 
  - `bondToken` field in `EscalationCostConfig` struct
  - Currently only supports single token
  - **TODO: Add list of accepted tokens (governance-controlled)**
- **Restrictions**: 
  - Currently single token only
  - No validation of token type (could be any ERC20 or ETH)
  - **TODO: Add whitelist of accepted stablecoins**

**Code References**:
- `DecentralizedResolverStructs.sol:123` - `address bondToken; // Token address for bond (address(0) = ETH)`
- `DecentralizedResolutionModule.sol:1280-1306` - Config queue/activate functions
- `DecentralizedResolutionModule.sol:526-541` - `getRequiredAppealBond()` returns bond token
- `DecentralizedResolutionModule.sol:221` - Default: `bondToken: address(0)`

**Current Implementation**:
```solidity
struct EscalationCostConfig {
    CostCurveType curveType;
    uint256 baseCost;
    uint256 stepSize;
    uint256 multiplier;
    address bondToken; // Single token only
    bool enabled;
}
```

### 4. Resolver Fee Payment Currency

**Location**: `ResolverIncentiveModuleV1/V2` payment distribution

- **Accepted**: Same token as escrow fee (which matches escrow amount)
- **Default**: Automatically matches escrow fee token
- **How Changed**: Cannot be changed independently
- **Restrictions**: 
  - **CRITICAL**: Fee-based payments are ALWAYS in the same token as the escrow fee
  - This is enforced because fees are recorded per-token, and payments are distributed from those fees
  - **NOTE**: This is separate from staking (which uses USDC + SEW)

**Code References**:
- `ResolverIncentiveModuleV1.sol:222-227` - `_recordEscrowFee(workflowId, token, amount)` stores token
- `ResolverIncentiveModuleV1.sol:392-400` - `distributePayments(workflowId, address token, uint256 totalFees)` uses token parameter
- `ResolverIncentiveModuleV1.sol:422-427` - Payment calculation uses stored escrow fee token
- `BaseEscrow.sol:749` - Escrow fee recorded with token: `incentiveMod.recordEscrowFee(workflowId, token, escrowFeeAmount)`

**Implementation Details**:
```solidity
// Escrow fee is recorded with token
_recordEscrowFee(workflowId, token, escrowFee);

// Later, payments are distributed in same token
distributePayments(workflowId, token, totalFees);
```

### 5. Resolver Staking Currency

**Location**: `ResolverStakingModuleV1`

- **Accepted**: USDC (stablecoin) + SEW (protocol token)
- **Default**: Fixed mix (80% USDC minimum, 20% SEW maximum)
- **How Changed**: Governance-controlled (staking module configuration)
- **Restrictions**: 
  - **CRITICAL**: Staking is NOT a payment mechanism - it's capital at risk
  - Mix must be 80% stable / 20% SEW minimum
  - SEW has 50% haircut in valuation
  - Separate from fee-based payments

**Code References**:
- `ResolverStakingModuleV1.sol:70-71` - Stable and SEW token addresses
- `ResolverStakingModuleV1.sol:49-51` - Mix constants (MIN_STABLE_BPS = 8000, MAX_SEW_BPS = 2000)
- `BondValuationLibrary.sol` - Bond valuation with haircut

**Implementation Details**:
```solidity
// Staking requires mix of stablecoin and SEW
stake(uint256 stableAmount, uint256 sewAmount);

// Effective bond = stableAmount + (sewAmount * 0.5) // 50% haircut
```

### 6. Slashing Currency

**Location**: `ResolverSlashingModuleV1`

- **Accepted**: Same as staked tokens (USDC + SEW)
- **Default**: Automatically matches staked tokens
- **How Changed**: Cannot be changed independently
- **Restrictions**: 
  - **CRITICAL**: Slashing reduces staked amounts
  - Slashed tokens go to insurance pool and protocol treasury
  - Separate from fee-based payments

**Code References**:
- `ResolverSlashingModuleV1.sol:54-56` - Staking module and tokens
- `ResolverSlashingModuleV1.sol:38-41` - Penalty percentages

**Implementation Details**:
```solidity
// Slash reduces staked amounts
slashForTimeout(...); // 2-10% penalty depending on offense
```

## Current Restrictions Summary

### Implemented Restrictions

1. **Escrow Fee = Escrow Amount Token**
   - Fees are always calculated and paid in the same token as the escrow amount
   - Enforced by code flow (no separate fee token parameter)
   - Location: `BaseEscrow.sol:476`, `EscrowVault.sol:103`

2. **Fee-Based Payments = Escrow Fee Token**
   - Resolver fee payments are always in the same token as escrow fees
   - Enforced because fees are recorded per-token and payments come from fees
   - Location: `ResolverIncentiveModuleV1.sol:222-227`, `392-400`
   - **NOTE**: This is separate from staking (which uses USDC + SEW)

3. **Staking = Fixed Mix (USDC + SEW)**
   - Staking requires 80% USDC minimum, 20% SEW maximum
   - SEW has 50% haircut in valuation
   - Location: `ResolverStakingModuleV1.sol:49-51`
   - **NOTE**: Staking is capital at risk, not a payment mechanism

4. **Slashing = Staked Tokens**
   - Slashing reduces staked USDC and SEW amounts
   - Location: `ResolverSlashingModuleV1.sol:54-56`

### Missing Restrictions (TODO)

1. **Appeal Bond Token Validation**
   - Currently accepts any token address
   - Should validate against whitelist of accepted stablecoins
   - Should prevent volatile tokens

2. **Appeal Bond Multi-Token Support**
   - Currently only supports single token
   - Should support list of accepted tokens (governance-controlled)

## Code Consistency Analysis

### Shared Libraries

All currency handling uses consistent patterns:

1. **SafeERC20 Library**: Used throughout for ERC20 transfers
   - `BaseEscrow.sol:56` - `using SafeERC20 for IERC20;`
   - `EscrowVault.sol:16` - `using SafeERC20 for IERC20;`
   - `ResolverIncentiveModuleV1.sol:11` - `using SafeERC20 for IERC20;`
   - `ResolverIncentiveModuleV2.sol:26` - `using SafeERC20 for IERC20;`

2. **Token Address Handling**: Consistent `address(0)` = ETH pattern
   - `DecentralizedResolverStructs.sol:123` - `address(0) = ETH`
   - `ResolverIncentiveModuleV2.sol:33` - `address(0) = ETH` in bond records
   - `BaseEscrow.sol:479` - `_pullTokens()` handles both ERC20 and ETH

3. **Fee Calculation**: Consistent basis points pattern
   - `BaseEscrow.sol:68` - `ESCROW_FEE_DENOMINATOR = 10000`
   - `PaymentCalculationLibraryV1.sol:15` - `BASIS_POINTS_DENOMINATOR = 10000`
   - `DecentralizedResolutionModule.sol:39` - `BASIS_POINTS_DENOMINATOR = 10000`

### Inconsistencies Found

1. **Bond Token Default**: Currently ETH (`address(0)`), but should be USD stablecoin
   - **Action**: Update default in constructor and documentation

2. **No Token Validation**: Appeal bond token is not validated
   - **Action**: Add whitelist validation

3. **Single Token Limitation**: Appeal bonds only support one token
   - **Action**: Add multi-token support with governance-controlled list

## Recommendations

1. **Update Default Bond Token**: Change default from ETH to USD stablecoin (e.g., USDC)
2. **Add Accepted Tokens List**: Implement governance-controlled whitelist for appeal bonds
3. **Add Token Validation**: Validate bond tokens against whitelist
4. **Document Currency Restrictions**: Ensure all restrictions are clearly documented
5. **Consider Multi-Token Bonds**: Allow users to pay bonds in any accepted stablecoin
