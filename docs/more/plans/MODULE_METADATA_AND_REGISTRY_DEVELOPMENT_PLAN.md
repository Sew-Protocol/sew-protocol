# Module Metadata and Registry - Development Plan

**Date**: 2025-01-XX  
**Status**: Planning  
**Purpose**: Implement module metadata and registry system as described in MODULE_METADATA_AND_REGISTRY.md

---

## Executive Summary

This plan implements a standardized module metadata system across all module types, ensuring consistent versioning, interface detection, and module identification. The implementation follows industry best practices (ERC-165, semantic versioning) and maintains backward compatibility.

**Timeline**: 1-2 weeks  
**Risk Level**: Low (additive changes, backward compatible)  
**Dependencies**: OpenZeppelin ERC165, existing module interfaces

---

## Current State Analysis

### Interface Status

| Interface                  | moduleName            | moduleVersion | supportsInterface | Status       |
| -------------------------- | --------------------- | ------------- | ----------------- | ------------ |
| `IResolutionModule`        | ✅ Yes                | ❌ No         | ❌ No             | Needs update |
| `IYieldGenerationModule`   | ✅ Yes                | ✅ Yes        | ✅ Yes            | Complete     |
| `IYieldDistributionModule` | ✅ Yes                | ✅ Yes        | ✅ Yes            | Complete     |
| `IReleaseStrategy`         | ✅ Yes (strategyName) | ❌ No         | ❌ No             | Needs update |

### Implementation Status

| Module                           | moduleName            | moduleVersion | supportsInterface | Status       |
| -------------------------------- | --------------------- | ------------- | ----------------- | ------------ |
| `DecentralizedResolutionModule`  | ✅ Yes                | ❌ No         | ❌ No             | Needs update |
| `DefaultResolutionModule`        | ✅ Yes                | ❌ No         | ❌ No             | Needs update |
| `AaveYieldGenerationModule`      | ✅ Yes                | ✅ Yes        | ✅ Yes            | Complete     |
| `DefaultYieldDistributionModule` | ✅ Yes                | ✅ Yes        | ✅ Yes            | Complete     |
| `DefaultReleaseStrategy`         | ✅ Yes (strategyName) | ❌ No         | ❌ No             | Needs update |

---

## Phase 1: Interface Standardization (Days 1-2)

### 1.1 Update IResolutionModule Interface

**Objective**: Add `moduleVersion()` and ERC-165 support to resolution module interface

**Tasks**:

- [ ] Add `IERC165` inheritance to `IResolutionModule`
- [ ] Add `moduleVersion()` function signature
- [ ] Document semantic versioning requirements

**Implementation**:

```solidity
// contracts/interfaces/IResolutionModule.sol
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

interface IResolutionModule is IERC165 {
  // ... existing functions ...

  /**
   * @notice Get the module version
   * @return version The module version (semantic versioning, e.g., "1.0.0")
   */
  function moduleVersion() external pure returns (string memory version);
}
```

**Files to Modify**:

- `contracts/interfaces/IResolutionModule.sol`

**Deliverables**:

- Updated interface with version and ERC-165 support
- Documentation updated

**Estimated Time**: 2-3 hours

---

### 1.2 Update IReleaseStrategy Interface

**Objective**: Add `moduleVersion()` and ERC-165 support, standardize naming

**Tasks**:

- [ ] Add `IERC165` inheritance to `IReleaseStrategy`
- [ ] Add `moduleVersion()` function signature
- [ ] Consider renaming `strategyName()` to `moduleName()` for consistency (or keep both for backward compatibility)
- [ ] Document semantic versioning requirements

**Implementation**:

```solidity
// contracts/interfaces/IReleaseStrategy.sol
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

interface IReleaseStrategy is IERC165 {
  // ... existing functions ...

  /**
   * @notice Get the module version
   * @return version The module version (semantic versioning, e.g., "1.0.0")
   */
  function moduleVersion() external pure returns (string memory version);

  /**
   * @notice Get the module name (alias for strategyName for consistency)
   * @return name The module name
   */
  function moduleName() external pure returns (string memory name);
}
```

**Files to Modify**:

- `contracts/interfaces/IReleaseStrategy.sol`

**Deliverables**:

- Updated interface with version and ERC-165 support
- Optional: `moduleName()` alias for consistency

**Estimated Time**: 2-3 hours

---

## Phase 2: Module Implementation Updates (Days 3-5) ✅ COMPLETE

### 2.1 Update DecentralizedResolutionModule ✅

**Objective**: Add `moduleVersion()` and `supportsInterface()` to DecentralizedResolutionModule

**Tasks**:

- [x] Add `moduleVersion()` pure function returning "1.0.0"
- [x] Implement `supportsInterface()` for ERC-165
- [x] Ensure interface ID calculation is correct
- [x] Update NatSpec documentation

**Implementation**:

```solidity
// contracts/modules/DecentralizedResolutionModule.sol
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

contract DecentralizedResolutionModule is
  AccessControlUpgradeable,
  ReentrancyGuardUpgradeable,
  IResolutionModule,
  SlowLaneQueueActivateUpgradeable,
  UUPSUpgradeable,
  ERC165Upgradeable // Add this
{
  // ... existing code ...

  function moduleName() external pure override returns (string memory name) {
    return 'DecentralizedResolutionModule';
  }

  function moduleVersion() external pure override returns (string memory version) {
    return '1.0.0';
  }

  function supportsInterface(
    bytes4 interfaceId
  )
    public
    view
    virtual
    override(AccessControlUpgradeable, ERC165Upgradeable, IERC165)
    returns (bool)
  {
    return
      interfaceId == type(IResolutionModule).interfaceId || super.supportsInterface(interfaceId);
  }
}
```

**Files to Modify**:

- `contracts/modules/DecentralizedResolutionModule.sol`

**Deliverables**:

- Module with version and ERC-165 support
- Tests updated

**Estimated Time**: 3-4 hours

---

### 2.2 Update DefaultResolutionModule ✅

**Objective**: Add `moduleVersion()` and `supportsInterface()` to DefaultResolutionModule

**Tasks**:

- [x] Add `moduleVersion()` pure function returning "1.0.0"
- [x] Implement `supportsInterface()` for ERC-165
- [x] Update NatSpec documentation

**Implementation**:

```solidity
// contracts/modules/DefaultResolutionModule.sol
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

contract DefaultResolutionModule is AccessControl, IResolutionModule, ERC165 {
  // ... existing code ...

  function moduleName() external pure override returns (string memory) {
    return 'DefaultResolutionModule';
  }

  function moduleVersion() external pure override returns (string memory version) {
    return '1.0.0';
  }

  function supportsInterface(
    bytes4 interfaceId
  ) public view virtual override(AccessControl, ERC165, IERC165) returns (bool) {
    return
      interfaceId == type(IResolutionModule).interfaceId || super.supportsInterface(interfaceId);
  }
}
```

**Files to Modify**:

- `contracts/modules/DefaultResolutionModule.sol`

**Deliverables**:

- Module with version and ERC-165 support
- Tests updated

**Estimated Time**: 2-3 hours

---

### 2.3 Update DefaultReleaseStrategy ✅

**Objective**: Add `moduleVersion()`, `moduleName()`, and `supportsInterface()` to DefaultReleaseStrategy

**Tasks**:

- [x] Add `moduleVersion()` pure function returning "1.0.0"
- [x] Add `moduleName()` pure function (alias for strategyName)
- [x] Implement `supportsInterface()` for ERC-165
- [x] Update NatSpec documentation

**Implementation**:

```solidity
// contracts/modules/DefaultReleaseStrategy.sol
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

contract DefaultReleaseStrategy is IReleaseStrategy, ERC165 {
  // ... existing code ...

  function strategyName() external pure override returns (string memory name) {
    return 'DefaultReleaseStrategy';
  }

  function moduleName() external pure returns (string memory name) {
    return 'DefaultReleaseStrategy';
  }

  function moduleVersion() external pure override returns (string memory version) {
    return '1.0.0';
  }

  function supportsInterface(
    bytes4 interfaceId
  ) public view virtual override(ERC165, IERC165) returns (bool) {
    return
      interfaceId == type(IReleaseStrategy).interfaceId || super.supportsInterface(interfaceId);
  }
}
```

**Files to Modify**:

- `contracts/modules/DefaultReleaseStrategy.sol`

**Deliverables**:

- Module with version and ERC-165 support
- Tests updated

**Estimated Time**: 2-3 hours

---

## Phase 3: Validation and Testing (Days 6-7) 🚧 IN PROGRESS

### 3.1 Module Validation Tests

**Objective**: Ensure all modules implement required metadata functions correctly

**Tasks**:

- [ ] Test `moduleName()` returns correct name for all modules
- [ ] Test `moduleVersion()` returns semantic version for all modules
- [ ] Test `supportsInterface()` returns correct interface IDs
- [ ] Test ERC-165 interface detection
- [ ] Test backward compatibility (existing code still works)

**Test Cases**:

```typescript
describe('Module Metadata', () => {
  it('Should return correct module name', async () => {
    expect(await module.moduleName()).to.equal('DecentralizedResolutionModule');
  });

  it('Should return semantic version', async () => {
    const version = await module.moduleVersion();
    expect(version).to.match(/^\d+\.\d+\.\d+$/); // Semantic version format
  });

  it('Should support IResolutionModule interface', async () => {
    const interfaceId = ethers.id('IResolutionModule').slice(0, 10);
    expect(await module.supportsInterface(interfaceId)).to.be.true;
  });

  it('Should support ERC165 interface', async () => {
    const erc165Id = '0x01ffc9a7'; // ERC165 interface ID
    expect(await module.supportsInterface(erc165Id)).to.be.true;
  });
});
```

**Files to Create/Modify**:

- `test/hardhat/ModuleMetadata.test.ts` (new)
- Update existing module tests

**Deliverables**:

- Comprehensive test suite
- All tests passing

**Estimated Time**: 4-6 hours

---

### 3.2 Integration Tests

**Objective**: Ensure module validation works in BaseEscrow

**Tasks**:

- [ ] Test module validation on registration
- [ ] Test interface detection in BaseEscrow
- [ ] Test version checking (if implemented)
- [ ] Test backward compatibility

**Test Cases**:

```typescript
describe('Module Validation in BaseEscrow', () => {
  it('Should validate module interface on registration', async () => {
    // Test that invalid modules are rejected
    // Test that valid modules are accepted
  });

  it('Should detect module interface correctly', async () => {
    const module = await deployModule();
    const interfaceId = type(IResolutionModule).interfaceId;
    expect(await module.supportsInterface(interfaceId)).to.be.true;
  });
});
```

**Files to Create/Modify**:

- `test/hardhat/BaseEscrow.moduleValidation.test.ts` (new)

**Deliverables**:

- Integration tests
- All tests passing

**Estimated Time**: 3-4 hours

---

## Phase 4: Module Registry (Optional) (Days 8-10)

### 4.1 Decision: Global Registry vs Per-Contract

**Objective**: Decide whether to implement global ModuleRegistry contract

**Options**:

1. **Option A**: Keep current per-contract approach (simple, gas-efficient)
2. **Option B**: Implement global ModuleRegistry (discoverable, centralized)

**Recommendation**: **Option A** for now

- Current approach is simple and gas-efficient
- No external dependency
- Global registry adds complexity without immediate benefit
- Can be added later if needed

**Decision Document**: Create `MODULE_REGISTRY_DECISION.md`

**Estimated Time**: 2-3 hours

---

### 4.2 ModuleRegistry Contract (If Option B Chosen)

**Objective**: Implement global module registry contract

**Tasks**:

- [ ] Design ModuleRegistry contract structure
- [ ] Implement registration functions
- [ ] Implement query functions
- [ ] Add governance controls
- [ ] Add tests

**Implementation**:

```solidity
contract ModuleRegistry {
    struct ModuleInfo {
        address implementation;
        string name;
        string version;
        bytes4 interfaceId;
        address owner;
        bool enabled;
        uint256 registeredAt;
    }

    mapping(bytes32 => ModuleInfo) public modules;
    mapping(address => bytes32) public moduleByAddress;

    function registerModule(...) external;
    function getModule(string memory name) external view returns (ModuleInfo memory);
}
```

**Files to Create**:

- `contracts/registry/ModuleRegistry.sol`
- `test/hardhat/ModuleRegistry.test.ts`

**Deliverables**:

- ModuleRegistry contract (if chosen)
- Tests
- Documentation

**Estimated Time**: 1-2 days (if implemented)

---

## Phase 5: Documentation and Best Practices (Days 11-12) ✅ COMPLETE

### 5.1 Update Documentation ✅

**Objective**: Document module metadata requirements and best practices

**Tasks**:

- [x] Update MODULE_METADATA_AND_REGISTRY.md with implementation status
- [x] Create module development guide
- [x] Document semantic versioning guidelines
- [x] Document interface ID calculation
- [x] Create examples for new modules

**Files to Create/Modify**:

- `docs/MODULE_METADATA_AND_REGISTRY.md` (update)
- `docs/MODULE_DEVELOPMENT_GUIDE.md` (new)

**Deliverables**:

- Complete documentation
- Development guide
- Examples

**Estimated Time**: 4-6 hours

---

### 5.2 Best Practices Enforcement ✅

**Objective**: Ensure all modules follow best practices

**Tasks**:

- [x] Review all modules for consistency
- [x] Verify naming conventions (PascalCase)
- [x] Verify version format (semantic versioning)
- [x] Verify interface ID implementation
- [x] Document best practices in development guide

**Deliverables**:

- Best practices checklist
- Validation tools (optional)

**Estimated Time**: 2-3 hours

---

## Implementation Checklist

### Phase 1: Interface Standardization

- [ ] Update `IResolutionModule` interface
- [ ] Update `IReleaseStrategy` interface
- [ ] Verify interface compatibility

### Phase 2: Module Implementation

- [ ] Update `DecentralizedResolutionModule`
- [ ] Update `DefaultResolutionModule`
- [ ] Update `DefaultReleaseStrategy`
- [ ] Verify all modules compile

### Phase 3: Testing

- [ ] Create module metadata tests
- [ ] Create integration tests
- [ ] Update existing tests
- [ ] All tests passing

### Phase 4: Registry (Optional)

- [ ] Make decision on global registry
- [ ] Implement if chosen
- [ ] Test registry

### Phase 5: Documentation

- [ ] Update documentation
- [ ] Create development guide
- [ ] Document best practices

---

## Risk Assessment

### Low Risk ✅

- Additive changes (no breaking changes)
- Backward compatible
- Well-tested patterns (ERC-165)

### Medium Risk ⚠️

- Interface changes require all implementations to update
- Need to ensure no regressions

### High Risk ❌

- None identified

---

## Success Criteria

### Phase 1 Success

- ✅ All interfaces have `moduleVersion()` and ERC-165 support
- ✅ Interfaces compile successfully
- ✅ Documentation updated

### Phase 2 Success

- ✅ All modules implement `moduleVersion()` and `supportsInterface()`
- ✅ All modules compile successfully
- ✅ No breaking changes

### Phase 3 Success

- ✅ All tests passing
- ✅ Module validation working
- ✅ Integration tests passing

### Phase 4 Success (If Implemented)

- ✅ ModuleRegistry deployed and tested
- ✅ Modules registered
- ✅ Query functions working

### Phase 5 Success

- ✅ Documentation complete
- ✅ Development guide created
- ✅ Best practices documented

---

## Timeline Summary

| Phase                              | Duration | Key Deliverables              |
| ---------------------------------- | -------- | ----------------------------- |
| Phase 1: Interface Standardization | 1-2 days | Updated interfaces            |
| Phase 2: Module Implementation     | 2-3 days | Updated modules               |
| Phase 3: Testing                   | 1-2 days | Test suite                    |
| Phase 4: Registry (Optional)       | 1-2 days | Registry contract (if chosen) |
| Phase 5: Documentation             | 1-2 days | Complete docs                 |

**Total Timeline**: 1-2 weeks (depending on registry decision)

---

## Dependencies

### External Dependencies

- OpenZeppelin ERC165 (already in use)
- OpenZeppelin AccessControl (already in use)

### Internal Dependencies

- Existing module interfaces
- Existing module implementations
- BaseEscrow module validation

---

## Next Steps

1. **Review and Approve Plan**: Review this plan and approve approach
2. **Start Phase 1**: Begin interface standardization
3. **Implement Phases Sequentially**: Complete each phase before moving to next
4. **Test Thoroughly**: Ensure all tests pass before proceeding
5. **Document Progress**: Update status as work progresses

---

_This plan should be updated as implementation progresses and decisions are made._
