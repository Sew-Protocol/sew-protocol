# Module Map

Complete mapping of module interfaces to implementations, including how to change modules.

## Module Architecture

The protocol uses a modular architecture where core functionality is split into swappable modules:

1. **Release Strategy** - Determines when and how escrow funds can be released
2. **Resolution Module** - Handles dispute resolution and escalation
3. **Yield Generation Module** - Generates yield on escrowed funds
4. **Yield Distribution Module** - Distributes generated yield to recipients

Each module type has an interface, and multiple implementations can exist. The protocol uses **default modules** that apply to all new escrows. Module changes are **snapshotted at escrow creation**, ensuring existing escrows are unaffected.

---

## Interface → Implementation Mapping

### IReleaseStrategy

| Implementation         | Contract                                       | Status    | Change Mechanism           |
| ---------------------- | ---------------------------------------------- | --------- | -------------------------- |
| DefaultReleaseStrategy | `contracts/modules/DefaultReleaseStrategy.sol` | ✅ Active | Slow lane (queue/activate) |

**Interface Methods**:

- `canRelease(uint256 workflowId, address caller, bytes calldata escrowData) → (bool, string)`
- `executeRelease(uint256 workflowId, bytes calldata escrowData) → (bool, address, uint256)`
- `strategyName() → string`

**Change Function**:

- `EscrowableERC20.queueDefaultReleaseStrategy(address)` / `activateDefaultReleaseStrategy()`
- `EscrowVault.queueDefaultReleaseStrategy(address)` / `activateDefaultReleaseStrategy()` (Phase 8: Lane consistency fix)

---

### IResolutionModule

| Implementation                | Contract                                                                      | Status              | Change Mechanism                                                                                                          |
| ----------------------------- | ----------------------------------------------------------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| DefaultResolutionModule       | `contracts/core/modules/DefaultResolutionModule.sol`                          | ✅ Active           | Slow lane (queue/activate)                                                                                                |
| DecentralizedResolutionModule | `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol` | 🔄 Separate Package | **Not in initial mainnet release**. When ready, will be deployed and swapped in via Slow lane (queue + activate, ~9 days) |

**Interface Methods**:

- `isAuthorizedResolver(uint256 workflowId, address resolver, bytes calldata escrowData) → (bool, uint8)`
- `getResolver(uint256 workflowId, bytes calldata escrowData) → (address, uint8)`
- `canEscalate(uint256 workflowId, uint8 currentLevel, bytes calldata escrowData) → (bool, address, uint256)`
- `executeEscalation(uint256 workflowId, bytes calldata escrowData) → (bool, address, uint8)`
- `moduleName() → string`

**Change Function**:

- `EscrowableERC20.queueDefaultResolutionModule(address)` / `activateDefaultResolutionModule()` - Slow lane (no-op, overridden)
- `EscrowVault.queueDefaultResolutionModule(address)` / `activateDefaultResolutionModule()` - Slow lane (~9 days)
- `BaseEscrow.queueResolutionModule(address)` / `activateResolutionModule()` - Slow lane (~9 days)

**Module-Specific Configuration**:

- `DefaultResolutionModule.setResolver(address)` - Standard lane (48h)
- `DecentralizedResolutionModule` (when swapped in): All configuration functions require `ROLE_TIMELOCK` via Standard lane (48h)

**Note**: All modules use the same governance pattern: Slow lane for module swaps (~9 days). Modules are immutable - upgrades via deploy new version + swap.

---

### IYieldGenerationModule

| Implementation            | Contract                                          | Status    | Change Mechanism           |
| ------------------------- | ------------------------------------------------- | --------- | -------------------------- |
| AaveYieldGenerationModule | `contracts/modules/AaveYieldGenerationModule.sol` | ✅ Active | Slow lane (queue/activate) |

**Interface Methods**:

- `depositForYield(uint256 workflowId, address token, uint256 amount) → (bool, uint256)`
- `withdrawWithYield(uint256 workflowId, address token, uint256 originalAmount) → (bool, uint256, uint256)`
- `withdrawProportional(uint256 workflowId, address token, uint256 amount, uint256 originalDeposit) → (bool, uint256)`
- `calculateYield(uint256 workflowId, address token) → uint256`
- `isTokenSupported(address token) → bool`
- `moduleName() → string`
- `moduleVersion() → string`

**Change Function**:

- `EscrowableERC20.queueDefaultYieldGenerationModule(address)` / `activateDefaultYieldGenerationModule()`
- `EscrowVault.queueDefaultYieldGenerationModule(address)` / `activateDefaultYieldGenerationModule()` (Phase 8: Lane consistency fix)

**Module-Specific Configuration**:

- `AaveYieldGenerationModule.setAaveEnabled(bool)` - Standard lane (48h, enable only)
- `AaveYieldGenerationModule.guardianDisableAave()` - Emergency lane (0h, down-only)
- `AaveYieldGenerationModule.queueAavePoolProvider(address)` / `activateAavePoolProvider()` - Slow lane
- `AaveYieldGenerationModule.registerTokenForAave(address, address)` - Standard lane (48h)
- `AaveYieldGenerationModule.setTokenCap(address, uint256)` - Standard lane (48h)
- `AaveYieldGenerationModule.guardianLowerTokenCap(address, uint256)` - Emergency lane (0h, down-only)

---

### IYieldDistributionModule

| Implementation                 | Contract                                               | Status    | Change Mechanism           |
| ------------------------------ | ------------------------------------------------------ | --------- | -------------------------- |
| DefaultYieldDistributionModule | `contracts/modules/DefaultYieldDistributionModule.sol` | ✅ Active | Slow lane (queue/activate) |

**Interface Methods**:

- `distributeYield(uint256 workflowId, address token, uint256 yieldAmount, bytes calldata distributionData) → (bool, uint256)`
- `moduleName() → string`
- `moduleVersion() → string`

**Change Function**:

- `EscrowableERC20.queueDefaultYieldDistributionModule(address)` / `activateDefaultYieldDistributionModule()`
- `EscrowVault.queueDefaultYieldDistributionModule(address)` / `activateDefaultYieldDistributionModule()` (Phase 8: Lane consistency fix)

**Distribution Configuration**:

- `BaseEscrow.setDefaultYieldDistribution(address[] recipients, uint256[] percentages)` - Standard lane (48h)
- **Note**: Per-escrow yield distribution is immutable at creation. It is determined by the snapshotted yield distribution module and any configuration parameters set at creation time.

---

## How to Change Modules

### For EscrowableERC20 (Slow Lane - Queue/Activate)

1. **Queue the new module**:

   ```solidity
   // Via Timelock (after governance proposal)
   escrowableERC20.queueDefaultResolutionModule(newModuleAddress);
   ```

2. **Wait 7 days** (enforced onchain via ETA)

3. **Activate the new module**:
   ```solidity
   // Via Timelock (after governance proposal)
   escrowableERC20.activateDefaultResolutionModule();
   ```

**Total Time**: ~9 days wall-clock (48h queue proposal + 7d wait + 48h activate proposal)

### For EscrowVault (Slow Lane - Queue/Activate)

1. **Queue the new module**:

   ```solidity
   // Via Timelock (after governance proposal)
   escrowVault.queueDefaultResolutionModule(newModuleAddress);
   ```

2. **Wait 7 days** (enforced onchain via ETA)

3. **Activate the new module**:
   ```solidity
   // Via Timelock (after governance proposal)
   escrowVault.activateDefaultResolutionModule();
   ```

**Total Time**: ~9 days wall-clock (48h queue proposal + 7d wait + 48h activate proposal)

**Note**: Phase 8 fix - EscrowVault now uses Slow lane (queue/activate) for consistency with EscrowableERC20, eliminating the governance lane escape hatch.

---

## Module Snapshotting

When an escrow is created, the current default modules are **snapshotted** into the escrow's state:

```solidity
struct EscrowTransfer {
  // ... other fields ...
  address snapshotResolutionModule;
  address snapshotReleaseStrategy;
  address snapshotYieldGenerationModule;
  address snapshotYieldDistributionModule;
}
```

**Key Guarantee**: Module changes only affect **new escrows**. Existing escrows continue using their snapshotted modules.

---

## Current Module Addresses

Module addresses are stored in deployment artifacts. To find current addresses:

```bash
# View deployment artifacts
cat deployments/hardhat/EscrowableERC20.json | jq .address
cat deployments/hardhat/DefaultResolutionModule.json | jq .address
```

Or use the governance tooling:

```typescript
import { getDeployedAddress } from './scripts/gov/addresses';
const moduleAddress = await getDeployedAddress(hre, 'DefaultResolutionModule');
```

---

## Adding New Module Implementations

To add a new module implementation:

1. **Implement the interface**:

   ```solidity
   contract MyNewResolutionModule is IResolutionModule, AccessControl {
     // Implement all interface methods
   }
   ```

2. **Deploy the module**:

   ```bash
   hardhat deploy --tags MyNewResolutionModule
   ```

3. **Queue/activate via governance** (Slow lane, ~9 days):
   - Create governance proposal to queue new module (48h delay)
   - Wait 7 days (slow lane delay)
   - Create governance proposal to activate new module (48h delay)
   - **Applies to**: EscrowVault, BaseEscrow (all use same pattern)

---

## Module Versioning

Modules should implement `moduleVersion()` returning semantic versioning (e.g., "1.0.0"). This helps track which version is active and enables upgrade paths.

---

## References

- `GOVERNANCE_SURFACE_MAP.md` - Complete function mapping
- `governance.md` - Governance model overview
- `contracts/interfaces/` - Interface definitions
