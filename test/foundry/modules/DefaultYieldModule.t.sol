// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/DefaultYieldModule.sol';
import '../../../contracts/interfaces/IYieldGenerationModule.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

/**
 * @title DefaultYieldModuleTest
 * @notice Comprehensive tests for DefaultYieldModule
 * @dev Goal: 99% coverage for DefaultYieldModule.sol
 * 
 * DefaultYieldModule is a no-op implementation that returns original amounts
 * with zero yield. Tests verify all interface functions work correctly.
 */
contract DefaultYieldModuleTest is Test {
    DefaultYieldModule public yieldModule;
    ERC20Mock public token;
    
    uint256 public constant AMOUNT = 1000e18;
    
    function setUp() public {
        yieldModule = new DefaultYieldModule();
        token = new ERC20Mock('Test Token', 'TEST', address(this), 10000000e18);
    }
    
    // ============ depositForYield Tests ============
    
    function test_depositForYield_returnsSuccess() public {
        (bool success, uint256 yieldTokenBalance) = yieldModule.depositForYield(
            1,
            address(token),
            AMOUNT,
            address(this)
        );
        
        assertTrue(success);
        assertEq(yieldTokenBalance, 0);
    }
    
    function test_depositForYield_zeroAmount() public {
        (bool success, uint256 yieldTokenBalance) = yieldModule.depositForYield(
            1,
            address(token),
            0,
            address(this)
        );
        
        assertTrue(success);
        assertEq(yieldTokenBalance, 0);
    }
    
    // ============ withdrawWithYield Tests ============
    
    function test_withdrawWithYield_returnsOriginalAmount() public {
        (bool success, uint256 actualAmount, uint256 yieldAmount) = yieldModule.withdrawWithYield(
            1,
            address(token),
            AMOUNT,
            address(this)
        );
        
        assertTrue(success);
        assertEq(actualAmount, AMOUNT);
        assertEq(yieldAmount, 0);
    }
    
    function test_withdrawWithYield_zeroAmount() public {
        (bool success, uint256 actualAmount, uint256 yieldAmount) = yieldModule.withdrawWithYield(
            1,
            address(token),
            0,
            address(this)
        );
        
        assertTrue(success);
        assertEq(actualAmount, 0);
        assertEq(yieldAmount, 0);
    }
    
    // ============ calculateYield Tests ============
    
    function test_calculateYield_returnsZero() public {
        uint256 yield = yieldModule.calculateYield(1, address(token), address(this));
        assertEq(yield, 0);
    }
    
    function test_calculateYield_differentWorkflowId() public {
        uint256 yield = yieldModule.calculateYield(999, address(token), address(this));
        assertEq(yield, 0);
    }
    
    // ============ isTokenSupported Tests ============
    
    function test_isTokenSupported_returnsFalse() public {
        bool supported = yieldModule.isTokenSupported(address(token));
        assertFalse(supported);
    }
    
    function test_isTokenSupported_zeroAddress() public {
        bool supported = yieldModule.isTokenSupported(address(0));
        assertFalse(supported);
    }
    
    // ============ getApprovalTarget Tests ============
    
    function test_getApprovalTarget_returnsZero() public {
        address target = yieldModule.getApprovalTarget(address(token));
        assertEq(target, address(0));
    }
    
    function test_getApprovalTarget_zeroAddress() public {
        address target = yieldModule.getApprovalTarget(address(0));
        assertEq(target, address(0));
    }
    
    // ============ getAavePoolAddress Tests ============
    
    function test_getAavePoolAddress_returnsZero() public {
        address pool = yieldModule.getAavePoolAddress();
        assertEq(pool, address(0));
    }
    
    // ============ getATokenAddress Tests ============
    
    function test_getATokenAddress_returnsZero() public {
        address aToken = yieldModule.getATokenAddress(address(token));
        assertEq(aToken, address(0));
    }
    
    // ============ Metadata Tests ============
    
    function test_moduleName() public {
        string memory name = yieldModule.moduleName();
        assertEq(name, 'DefaultNoYield');
    }
    
    function test_moduleVersion() public {
        string memory version = yieldModule.moduleVersion();
        assertEq(version, '1.0.0');
    }
    
    // ============ ERC165 Tests ============
    
    function test_supportsInterface_IYieldGenerationModule() public {
        bool supported = yieldModule.supportsInterface(type(IYieldGenerationModule).interfaceId);
        assertTrue(supported);
    }
    
    function test_supportsInterface_IERC165() public {
        bool supported = yieldModule.supportsInterface(type(IERC165).interfaceId);
        assertTrue(supported);
    }
    
    function test_supportsInterface_unknown() public {
        bool supported = yieldModule.supportsInterface(0x12345678);
        assertFalse(supported);
    }
}
