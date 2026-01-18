# Test Update Prompt for Claude Haiku

## Context

The codebase has undergone significant architectural changes. All tests need to be updated to reflect the new immutable swappable pattern and governance model.

## Critical Changes to Apply

### 1. UUPS → Immutable Swappable Pattern

**All contracts converted from UUPS upgradeable to immutable constructor-based:**

- **Before**: Contracts used `initialize()` function with `initializer` modifier
- **After**: Contracts use `constructor()` with direct parameters

**Affected Contracts:**

- `KlerosArbitrableProxy` - now uses `constructor(address _arbitrator, address _admin)`
- `ResolverIncentiveModuleV1` - now uses `constructor(address initialOwner, address initialLibrary)`
- `ResolverIncentiveModuleV2` - inherits from V1, uses same constructor pattern
- `ResolverSlashingModuleV1` - now uses `constructor(address initialOwner, address _stakingModule, address _insurancePoolVault, address _stableToken)`
- `ResolverStakingModuleV1` - now uses `constructor(address initialOwner, address _stableToken, address _sewToken)`
- `InsurancePoolVault` - now uses `constructor(address initialOwner, address _stableToken)`
- `SlashingModuleNoOp` - now uses `constructor(address initialOwner)`
- `StakingModuleNoOp` - now uses `constructor(address initialOwner)`

**Test Changes Required:**

- Replace all `initialize()` calls with `new ContractName(...)` constructor calls
- Remove any proxy deployment patterns (ERC1967Proxy, UUPS proxy setup)
- Deploy contracts directly as immutable instances
- Remove `__UUPSUpgradeable_init()`, `__AccessControl_init()`, `__ReentrancyGuard_init()` calls
- Remove `_authorizeUpgrade()` function tests

### 2. ROLE_ADMIN → ROLE_TIMELOCK

**All governance roles standardized:**

- **Removed**: `ROLE_ADMIN` constant and all grants
- **Replaced with**: `ROLE_TIMELOCK` for all governance functions
- **Emergency role**: `ROLE_GUARDIAN` (for pause/unpause, down-only actions)

**Test Changes Required:**

- Replace all `ROLE_ADMIN` references with `ROLE_TIMELOCK`
- Update role grant/revoke tests to use `ROLE_TIMELOCK`
- Update access control tests to verify `ROLE_TIMELOCK` instead of `ROLE_ADMIN`
- Remove any tests that check for `ROLE_ADMIN` existence
- Update test setup to grant `ROLE_TIMELOCK` to test accounts instead of `ROLE_ADMIN`

**Example:**

```solidity
// Before
bytes32 ROLE_ADMIN = contract.ROLE_ADMIN();
await contract.grantRole(ROLE_ADMIN, account);

// After
bytes32 ROLE_TIMELOCK = contract.ROLE_TIMELOCK();
await contract.grantRole(ROLE_TIMELOCK, account);
```

### 3. remainingBalance Removed from Resolution Flow

**Resolution now always uses full balance:**

- **Removed**: Concept of partial resolution
- **Current**: All resolutions are full (`et.remainingBalance` is always the full amount)
- **Note**: `remainingBalance` field still exists in `EscrowTransfer` struct for accounting, but resolution always uses full amount

**Test Changes Required:**

- Remove any tests for partial resolution scenarios
- Update resolution tests to expect full balance transfers only
- Remove tests that verify partial amount calculations
- Update payment distribution tests if they relied on partial resolution logic

### 4. partialResolution Function Removed

**No partial resolution support:**

- **Removed**: Any `partialResolution()` or similar functions
- **Current**: Only full resolution via `releaseAsDisputeResolver()` and `cancelAsDisputeResolver()`

**Test Changes Required:**

- Remove all tests for `partialResolution()` function
- Remove tests that verify partial resolution amounts
- Update any tests that called partial resolution functions

### 5. Dispute Resolution Current State

**Key architectural changes:**

**DecentralizedResolutionModule:**

- **NOW IMMUTABLE**: Converted to use `AccessControl`, `ReentrancyGuard`, `ERC165` (non-upgradeable)
- Uses `constructor(address initialOwner)` function (not `initialize()`)
- Uses `SlowLaneQueueActivate` (not upgradeable version)
- Has `ROLE_TIMELOCK` constant (not `ROLE_ADMIN`)
- Implements round-based escalation (0=resolver, 1=senior, 2=external/Kleros)
- Uses appeal window pattern (pending settlements after resolution)

**Resolution Flow:**

1. Dispute raised → `EscrowState.DISPUTED`
2. Resolver assigned via `selectResolverRoundRobin()`
3. Resolver calls `releaseAsDisputeResolver()` or `cancelAsDisputeResolver()`
4. Resolution recorded → `PendingSettlement` created with appeal deadline
5. After appeal window → settlement finalized (state → `RESOLVED`)

**Test Changes Required:**

- **Update**: `DecentralizedResolutionModule` now uses `constructor(address initialOwner)` - deploy directly, no `initialize()` call
- Update tests to use `ROLE_TIMELOCK` for governance functions
- Verify appeal window enforcement in resolution tests
- Test pending settlement pattern (resolution → appeal window → finalization)
- Remove any proxy deployment patterns for `DecentralizedResolutionModule`

### 6. Constructor Pattern for Immutable Contracts

**New deployment pattern:**

```solidity
// Before (UUPS)
const impl = await ResolverIncentiveModuleV1.deploy();
const proxy = await ERC1967Proxy.deploy(impl.address, impl.interface.encodeFunctionData("initialize", [owner, library]));
const module = await ethers.getContractAt("ResolverIncentiveModuleV1", proxy.address);
await module.initialize(owner, library);

// After (Immutable)
const module = await ResolverIncentiveModuleV1.deploy(owner, library);
```

**Test Changes Required:**

- Update all deployment code to use constructors directly
- Remove proxy deployment helpers
- Update contract address references (no proxy addresses)
- Remove upgrade tests (contracts are immutable)

### 7. Import Path Updates

**Some imports changed:**

- `ResolverIncentiveModuleV1` now imports `@governance/SlowLaneQueueActivate.sol` (note the `@governance` alias)
- Other modules may have similar import path changes

**Test Changes Required:**

- Verify import paths in test setup files
- Update any hardcoded import paths if needed

## Testing Checklist

For each test file, verify:

- [ ] All `initialize()` calls replaced with constructor calls
- [ ] All `ROLE_ADMIN` references replaced with `ROLE_TIMELOCK`
- [ ] Proxy deployment patterns removed
- [ ] Partial resolution tests removed
- [ ] `remainingBalance` partial logic tests removed
- [ ] Upgrade tests removed (for immutable contracts)
- [ ] Constructor parameters match new signatures
- [ ] Role grants use `ROLE_TIMELOCK` instead of `ROLE_ADMIN`
- [ ] `DecentralizedResolutionModule` still uses `initialize()` (it's still upgradeable)
- [ ] Appeal window and pending settlement tests are present

## Priority Test Files

Focus on these test files first:

1. `test/hardhat/decentralized-resolution-module/DecentralizedResolutionModule.test.ts`
2. `test/hardhat/decentralized-resolution-module/ResolverIncentiveModule.test.ts`
3. `test/hardhat/KlerosIntegration.test.ts`
4. `test/foundry/decentralized-resolution-module/DRv2AppealBonds.t.sol`
5. `test/foundry/migrated/KlerosIntegration.test.t.sol`

## Notes

- **ALL modules are now immutable**: `DecentralizedResolutionModule` and all supporting modules use constructors
- No upgradeable contracts remain - all use immutable swappable pattern
- Tests should deploy all contracts directly using constructors, no proxy patterns
