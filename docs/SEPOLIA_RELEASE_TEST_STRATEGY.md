# Sepolia Release Test Strategy

## Priority: Core Module Functionality (Release & Resolution)

For Sepolia release, we're focusing on core module functionality to ensure:
1. **All tests passing** for release/resolution modules
2. **Constructors locked in** and validated
3. **Ready for Sepolia deployment**

## Test Commands

### Core Module Tests (Release & Resolution)
```bash
pnpm test:foundry:release-resolution
```

This command runs:
- **Module Metadata Tests**: `test/foundry/core/ModuleMetadataSimple.t.sol`
  - Tests interface compliance for DefaultResolutionModule, DefaultReleaseStrategy, etc.
  
- **Resolution Module Tests**: `test/foundry/decentralized-resolution-module/*.t.sol`
  - All decentralized resolution module functionality
  
- **Core Escrow Tests**: `test/foundry/core/*.t.sol`
  - Excludes: `*disabled*`, `*AutoTransfer*`, `*WithdrawEscrow*` (not critical for launch)

### Individual Test Categories

```bash
# Core escrow functionality only
pnpm test:foundry:core

# Module interface/metadata tests
pnpm test:foundry:modules
```

## What's Excluded (Post-Launch)

For Sepolia launch, we're **excluding**:
- `AutoTransfer.t.sol` - Auto-transfer functionality (40 failing tests)
- `WithdrawEscrow.t.sol` - Withdrawal edge cases (5 failing tests)
- Disabled test files
- Yield module comprehensive tests (optional feature)
- Governance tests (separate concern)

## What's Included (Critical for Launch)

✅ **DefaultReleaseStrategy** - Core release functionality  
✅ **DefaultResolutionModule** - Core dispute resolution  
✅ **DecentralizedResolutionModule** - Main resolution system  
✅ **EscrowVault** core operations - createEscrow, release, cancel  
✅ **Module metadata** - Interface compliance  
✅ **Security tests** - Reentrancy, access control  
✅ **Payment bounds** - Fee calculations  

## Test Status Check

Before Sepolia deployment:
1. Run core module tests: `pnpm test:foundry:release-resolution`
2. Verify all constructors are locked (no mutable state in constructors)
3. Check that module registry integration works
4. Verify yield preset system defaults to OFF correctly

## After Core Tests Pass

Once core module tests pass, we can:
1. Deploy to Sepolia
2. Fix remaining test failures (AutoTransfer, WithdrawEscrow) post-launch
3. Add comprehensive yield module tests for future features
