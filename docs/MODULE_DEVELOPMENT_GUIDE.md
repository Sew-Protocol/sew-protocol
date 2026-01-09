# Module Development Guide

## Overview

This guide provides step-by-step instructions for developing new modules that integrate with the escrow system. All modules must implement standardized metadata functions for versioning, identification, and interface detection.

## Table of Contents

1. [Module Requirements](#module-requirements)
2. [Creating a New Module](#creating-a-new-module)
3. [Semantic Versioning](#semantic-versioning)
4. [Interface Detection (ERC-165)](#interface-detection-erc-165)
5. [Best Practices](#best-practices)
6. [Testing](#testing)
7. [Examples](#examples)

---

## Module Requirements

### Required Functions

All modules must implement:

1. **`moduleName()`** - Returns a unique identifier for the module
   ```solidity
   function moduleName() external pure returns (string memory name);
   ```

2. **`moduleVersion()`** - Returns semantic version string
   ```solidity
   function moduleVersion() external pure returns (string memory version);
   ```

3. **`supportsInterface(bytes4 interfaceId)`** - ERC-165 interface detection
   ```solidity
   function supportsInterface(bytes4 interfaceId) 
       public view virtual override returns (bool);
   ```

### Required Inheritance

- **ERC-165**: All modules must inherit from `IERC165` or a contract that implements it (e.g., `ERC165`, `AccessControl`)
- **Interface**: Modules must implement their respective interface (e.g., `IResolutionModule`, `IReleaseStrategy`)

---

## Creating a New Module

### Step 1: Define the Interface

If creating a new module type, define the interface:

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IMyModule is IERC165 {
    // Module-specific functions
    function doSomething(uint256 param) external returns (bool);
    
    // Required metadata functions
    function moduleName() external pure returns (string memory name);
    function moduleVersion() external pure returns (string memory version);
}
```

### Step 2: Implement the Module

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./interfaces/IMyModule.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract MyModule is IMyModule, ERC165 {
    // Module implementation
    
    function doSomething(uint256 param) external override returns (bool) {
        // Implementation
        return true;
    }
    
    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure override returns (string memory name) {
        return "MyModule";
    }
    
    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning)
     */
    function moduleVersion() external pure override returns (string memory version) {
        return "1.0.0";
    }
    
    /**
     * @notice Check if contract supports an interface
     * @param interfaceId The interface identifier
     * @return supported True if interface is supported
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IMyModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
```

### Step 3: Add Access Control (If Needed)

For modules that require governance:

```solidity
import "@openzeppelin/contracts/access/AccessControl.sol";

contract MyModule is IMyModule, AccessControl, ERC165 {
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    
    constructor(address initialOwner) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }
    
    // AccessControl already includes ERC165, so override correctly:
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControl, ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IMyModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
```

---

## Semantic Versioning

### Format

All modules must use semantic versioning: **MAJOR.MINOR.PATCH**

- **MAJOR**: Breaking changes (incompatible API changes)
- **MINOR**: New functionality (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

### Examples

```solidity
// Initial release
function moduleVersion() external pure override returns (string memory version) {
    return "1.0.0";
}

// Bug fix
function moduleVersion() external pure override returns (string memory version) {
    return "1.0.1";
}

// New feature (backward compatible)
function moduleVersion() external pure override returns (string memory version) {
    return "1.1.0";
}

// Breaking change
function moduleVersion() external pure override returns (string memory version) {
    return "2.0.0";
}
```

### Versioning Guidelines

1. **Start at 1.0.0**: First stable release should be "1.0.0"
2. **Increment PATCH**: For bug fixes that don't change behavior
3. **Increment MINOR**: For new features that remain backward compatible
4. **Increment MAJOR**: For breaking changes that require updates to dependent code

---

## Interface Detection (ERC-165)

### Implementation Pattern

```solidity
function supportsInterface(bytes4 interfaceId)
    public
    view
    virtual
    override(ERC165, IERC165)  // Or AccessControl, ERC165, IERC165
    returns (bool)
{
    return
        interfaceId == type(IMyModule).interfaceId ||
        super.supportsInterface(interfaceId);
}
```

### Interface ID Calculation

Solidity automatically calculates interface IDs using `type(Interface).interfaceId`. This is the XOR of all function selectors in the interface.

**Manual Calculation (for reference):**
```solidity
// Interface ID = XOR of all function selectors
bytes4 selector1 = bytes4(keccak256("function1(uint256)"));
bytes4 selector2 = bytes4(keccak256("function2()"));
bytes4 interfaceId = selector1 ^ selector2;
```

**Using Solidity (recommended):**
```solidity
bytes4 interfaceId = type(IMyModule).interfaceId;
```

### Testing Interface Support

```typescript
// In tests
const interfaceId = await getInterfaceId(); // Calculate or use type().interfaceId
const supports = await module.supportsInterface(interfaceId);
expect(supports).to.be.true;
```

---

## Best Practices

### 1. Naming Conventions

- **Module Names**: Use PascalCase, descriptive names
  - ✅ Good: "DecentralizedResolution", "AaveYieldGeneration"
  - ❌ Bad: "Module1", "Resolver", "Aave"

- **Function Names**: Use camelCase
  - ✅ Good: `moduleName()`, `getResolver()`
  - ❌ Bad: `ModuleName()`, `get_resolver()`

### 2. Documentation

Always include NatSpec documentation:

```solidity
/**
 * @title MyModule
 * @notice Brief description of what the module does
 * @dev Detailed technical documentation
 */
contract MyModule is IMyModule {
    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure override returns (string memory name) {
        return "MyModule";
    }
}
```

### 3. Error Handling

Use custom errors for gas efficiency:

```solidity
error InvalidParameter(string reason);
error Unauthorized(address caller);

function doSomething(uint256 param) external {
    if (param == 0) {
        revert InvalidParameter("Parameter cannot be zero");
    }
    if (!hasRole(ROLE_TIMELOCK, msg.sender)) {
        revert Unauthorized(msg.sender);
    }
    // Implementation
}
```

### 4. Events

Emit events for important state changes:

```solidity
event ModuleConfigured(address indexed module, bytes32 indexed config);
event ResolverUpdated(address indexed oldResolver, address indexed newResolver);

function configure(bytes32 config) external {
    emit ModuleConfigured(address(this), config);
}
```

### 5. Access Control

Use OpenZeppelin's `AccessControl` for governance:

```solidity
import "@openzeppelin/contracts/access/AccessControl.sol";

bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
bytes32 public constant ROLE_GUARDIAN = keccak256("ROLE_GUARDIAN");

modifier onlyTimelock() {
    require(hasRole(ROLE_TIMELOCK, msg.sender), "Not timelock");
    _;
}
```

---

## Testing

### Test Structure

```typescript
describe("MyModule", function () {
    let module: MyModule;
    let deployer: SignerWithAddress;
    
    beforeEach(async function () {
        [deployer] = await ethers.getSigners();
        const ModuleFactory = await ethers.getContractFactory("MyModule");
        module = await ModuleFactory.deploy(deployer.address);
        await module.waitForDeployment();
    });
    
    describe("Module Metadata", function () {
        it("Should return correct module name", async function () {
            const name = await module.moduleName();
            expect(name).to.equal("MyModule");
        });
        
        it("Should return semantic version", async function () {
            const version = await module.moduleVersion();
            expect(version).to.match(/^\d+\.\d+\.\d+$/);
            expect(version).to.equal("1.0.0");
        });
        
        it("Should support IMyModule interface", async function () {
            const interfaceId = await getInterfaceId();
            const supports = await module.supportsInterface(interfaceId);
            expect(supports).to.be.true;
        });
        
        it("Should support ERC165 interface", async function () {
            const erc165Id = "0x01ffc9a7";
            const supports = await module.supportsInterface(erc165Id);
            expect(supports).to.be.true;
        });
    });
    
    describe("Module Functionality", function () {
        // Test module-specific functionality
    });
});
```

### Required Test Cases

1. ✅ Module name returns correct value
2. ✅ Module version follows semantic versioning format
3. ✅ `supportsInterface()` returns true for module interface
4. ✅ `supportsInterface()` returns true for ERC-165
5. ✅ `supportsInterface()` returns false for invalid interfaces
6. ✅ Module-specific functionality works correctly

---

## Examples

### Example 1: Simple Resolution Module

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IResolutionModule.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract SimpleResolutionModule is AccessControl, IResolutionModule {
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    address public resolver;
    
    constructor(address initialOwner, address initialResolver) {
        resolver = initialResolver;
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }
    
    function isAuthorizedResolver(
        uint256 /* workflowId */,
        address checkResolver,
        bytes calldata /* escrowData */
    ) external view override returns (bool authorized, uint8 role) {
        authorized = (checkResolver == resolver);
        role = 0;
        return (authorized, role);
    }
    
    function getResolver(
        uint256 /* workflowId */,
        bytes calldata /* escrowData */
    ) external view override returns (address resolver_, uint8 escalationLevel) {
        return (resolver, 0);
    }
    
    function canEscalate(
        uint256 /* workflowId */,
        uint8 /* currentLevel */,
        bytes calldata /* escrowData */
    ) external pure override returns (
        bool allowed,
        address nextResolver,
        uint256 escalationFee
    ) {
        return (false, address(0), 0);
    }
    
    function executeEscalation(
        uint256 /* workflowId */,
        bytes calldata /* escrowData */
    ) external pure override returns (
        bool success,
        address newResolver,
        uint8 newLevel
    ) {
        return (false, address(0), 0);
    }
    
    function moduleName() external pure override returns (string memory name) {
        return "SimpleResolution";
    }
    
    function moduleVersion() external pure override returns (string memory version) {
        return "1.0.0";
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControl, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IResolutionModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
```

### Example 2: Upgradeable Module (UUPS)

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IResolutionModule.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract UpgradeableResolutionModule is 
    AccessControlUpgradeable,
    IResolutionModule,
    UUPSUpgradeable
{
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    
    function initialize(address initialOwner) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }
    
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ROLE_TIMELOCK)
    {}
    
    // ... implement IResolutionModule functions ...
    
    function moduleName() external pure override returns (string memory name) {
        return "UpgradeableResolution";
    }
    
    function moduleVersion() external pure override returns (string memory version) {
        return "1.0.0";
    }
    
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IResolutionModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
```

---

## Checklist

Before deploying a new module, ensure:

- [ ] Module implements `moduleName()` returning a unique identifier
- [ ] Module implements `moduleVersion()` following semantic versioning
- [ ] Module implements `supportsInterface()` for ERC-165
- [ ] Module inherits from appropriate base contracts (ERC165, AccessControl, etc.)
- [ ] All functions have NatSpec documentation
- [ ] Module has comprehensive test coverage
- [ ] Tests verify metadata functions
- [ ] Tests verify interface detection
- [ ] Module follows naming conventions
- [ ] Access control is properly configured (if needed)
- [ ] Events are emitted for important state changes
- [ ] Custom errors are used instead of require strings (where applicable)

---

## References

- [ERC-165: Standard Interface Detection](https://eips.ethereum.org/EIPS/eip-165)
- [Semantic Versioning Specification](https://semver.org/)
- [OpenZeppelin Contracts Documentation](https://docs.openzeppelin.com/contracts)
- [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)

---

*Last Updated: 2025-01-XX*





