# Test Update Guide - Access Control Changes

**Date**: 2026-01-27  
**Purpose**: Guide for updating test files to work with new access control on ops contracts

---

## Summary of Changes

All ops contracts now require access control:
- `CreateOps` - requires `ROLE_ESCROW_CONTRACT`
- `DisputeOps` - requires `ROLE_ESCROW_CONTRACT`
- `SettlementOps` - requires `ROLE_ESCROW_CONTRACT`
- `YieldOps` - requires `ROLE_ESCROW_CONTRACT`
- `BondCollector` - requires `ROLE_ESCROW_CONTRACT`

All ops contracts now have constructors that require `initialOwner` parameter.

---

## Update Pattern for Test Files

### Step 1: Add Imports

```solidity
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
```

### Step 2: Add Variable Declarations

```solidity
SettlementOps public settlementOps;
CreateOps public createOps;
BondCollector public bondCollector;
```

### Step 3: Deploy Ops Contracts in setUp()

```solidity
yieldOps = new YieldOps(address(this));
disputeOps = new DisputeOps(address(this));  // Now requires initialOwner
settlementOps = new SettlementOps(address(this));
createOps = new CreateOps(address(this));
bondCollector = new BondCollector(address(this));
```

### Step 4: Register Escrow Contract with All Ops Contracts

```solidity
// After deploying escrow contract (vault or escrowableERC20)
yieldOps.registerEscrowContract(address(vault));
disputeOps.registerEscrowContract(address(vault));
settlementOps.registerEscrowContract(address(vault));
createOps.registerEscrowContract(address(vault));
bondCollector.registerEscrowContract(address(vault));
```

### Step 5: Set Ops Contracts in Escrow Contract

```solidity
// Grant ROLE_ADMIN_CONTRACT to test contract
vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));

// Set ops contracts
vault.setCreateOps(address(createOps));
vault.setSettlementOps(address(settlementOps));
vault.setBondCollector(address(bondCollector));
```

---

## Files Updated

### ✅ Fully Updated (All Ops + BondCollector)
- `test/foundry/core/EscrowVaultUniqueCoverage.t.sol`
- `test/foundry/core/EscrowEdgeCases.t.sol`
- `test/foundry/core/AppealWindowEnforcement.t.sol` (already had all)
- `test/foundry/core/WithdrawEscrow.t.sol`

### ✅ Partially Updated (Missing BondCollector)
- `test/foundry/core/EscrowConstraints.t.sol` (has YieldOps registration)
- `test/foundry/core/ReentrancyProtection.t.sol` (has YieldOps registration)
- `test/foundry/core/BaseEscrowComprehensive.t.sol` (has YieldOps registration)

### ⚠️ Needs Update
- `test/foundry/core/ProtocolFeeCalculation.t.sol`
- `test/foundry/core/AutoTransfer.t.sol`
- `test/foundry/core/ConstructorValidation.t.sol`
- `test/foundry/migrated/*.t.sol` (multiple files)
- `test/foundry/decentralized-resolution-module/*.t.sol` (multiple files)
- `test/foundry/governance/*.t.sol` (multiple files)

---

## Example: Complete setUp() Function

```solidity
function setUp() public {
    owner = address(this);
    timelock = address(0x1111);
    feeAddress = address(0xFEE);
    resolver = address(0x1234);
    buyer = address(0x1001);
    seller = address(0x1002);

    // Deploy modules
    resolutionModule = new DefaultResolutionModule(owner, resolver);
    releaseStrategy = new DefaultReleaseStrategy();
    token = new ERC20Mock('Test Token', 'TEST', owner, 10000000e18);

    // Deploy ops contracts
    yieldOps = new YieldOps(address(this));
    disputeOps = new DisputeOps(address(this));
    settlementOps = new SettlementOps(address(this));
    createOps = new CreateOps(address(this));
    bondCollector = new BondCollector(address(this));
    moduleManagement = new ModuleManagementContract(address(this));
    adminContract = new EscrowAdminContract(address(this));

    // Deploy escrow contract
    vault = new EscrowVault(
        ESCROW_FEE,
        feeAddress,
        address(yieldOps),
        address(disputeOps),
        address(moduleManagement)
    );

    // Register escrow contract with ModuleManagementContract
    moduleManagement.registerEscrowContract(address(vault));

    // Register escrow contract with all ops contracts
    yieldOps.registerEscrowContract(address(vault));
    disputeOps.registerEscrowContract(address(vault));
    settlementOps.registerEscrowContract(address(vault));
    createOps.registerEscrowContract(address(vault));
    bondCollector.registerEscrowContract(address(vault));

    // Setup roles
    vault.grantRole(vault.ROLE_TIMELOCK(), owner);
    vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
    adminContract.grantRole(adminContract.ROLE_TIMELOCK(), owner);
    adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

    // Wire ops contracts on the vault
    vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
    vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
    vault.setCreateOps(address(createOps));
    vault.setSettlementOps(address(settlementOps));
    vault.setBondCollector(address(bondCollector));

    // Setup modules (queue/activate pattern)
    adminContract.queueResolutionModule(address(vault), address(resolutionModule));
    // ... rest of module setup
}
```

---

## Common Issues

### Issue 1: `AccessControlUnauthorizedAccount` Error

**Symptom**: Tests fail with `AccessControlUnauthorizedAccount` when calling ops contract functions.

**Solution**: Make sure you've registered the escrow contract with the ops contract:
```solidity
createOps.registerEscrowContract(address(vault));
```

### Issue 2: `ZeroCreateOps()` Error

**Symptom**: Tests fail with `ZeroCreateOps()` when creating escrows.

**Solution**: Make sure you've set the ops contracts in the escrow contract:
```solidity
vault.setCreateOps(address(createOps));
```

### Issue 3: Constructor Errors

**Symptom**: `DisputeOps` constructor fails.

**Solution**: `DisputeOps` now requires `initialOwner` parameter:
```solidity
// Before:
disputeOps = new DisputeOps();

// After:
disputeOps = new DisputeOps(address(this));
```

---

## Quick Checklist

For each test file that uses `EscrowVault` or `EscrowableERC20`:

- [ ] Add imports for `SettlementOps`, `CreateOps`, `BondCollector`
- [ ] Add variable declarations for ops contracts
- [ ] Deploy all ops contracts with `address(this)` as `initialOwner`
- [ ] Register escrow contract with all 5 ops contracts
- [ ] Grant `ROLE_ADMIN_CONTRACT` to test contract
- [ ] Set ops contracts in escrow (`setCreateOps`, `setSettlementOps`, `setBondCollector`)
- [ ] Update `DisputeOps` constructor call (add `initialOwner` parameter)

---

## Notes

- All ops contracts use the same pattern: `new XxxOps(address(this))` where `address(this)` is the test contract
- Registration is idempotent - safe to call multiple times
- Some tests may not need all ops contracts (e.g., if they don't test escalation, they may not need `BondCollector`)
- For tests that only need basic functionality, at minimum they need `CreateOps` for escrow creation
