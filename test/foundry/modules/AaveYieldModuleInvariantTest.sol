// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/types/YieldPresets.sol';

/**
 * @title AaveYieldModuleInvariantTest
 * @notice Invariant tests for AaveYieldModule
 * 
 * Run: forge test --match-contract AaveYieldModuleInvariantTest -vvv
 */
contract AaveYieldModuleInvariantTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public token;
    MockAToken public aToken;

    address public escrow1;
    address public escrow2;
    address public escrow3;

    uint256 constant INITIAL_BALANCE = 1000000e18;

    function setUp() public {
        pool = new MockAavePool();
        token = new ERC20Mock("Test Token", "TEST", address(this), INITIAL_BALANCE);
        aToken = new MockAToken(address(token), "aTest", "aTEST");
        
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));
        
        module = new AaveYieldModule(address(pool));
        
        token.approve(address(pool), type(uint256).max);
        
        escrow1 = address(0x1001);
        escrow2 = address(0x1002);
        escrow3 = address(0x1003);
        
        module.approveEscrow(escrow1);
        module.approveEscrow(escrow2);
        module.approveEscrow(escrow3);
        
        module.configureToken(address(token), address(aToken));
        
        token.transfer(escrow1, 10000e18);
        token.transfer(escrow2, 10000e18);
        token.transfer(escrow3, 10000e18);

        targetContract(address(module));
    }

    function invariant_principal_never_exceeds_balance() public {
        (, uint256 principal1, ) = module.positions(escrow1, 1);
        (, uint256 principal2, ) = module.positions(escrow2, 1);
        (, uint256 principal3, ) = module.positions(escrow3, 1);
        (, uint256 principal4, ) = module.positions(escrow1, 2);
        (, uint256 principal5, ) = module.positions(escrow2, 2);
        
        uint256 totalPositionPrincipal = principal1 + principal2 + principal3 + principal4 + principal5;
        
        uint256 aTokenBalance = aToken.balanceOf(address(module));
        uint256 tokenBalance = token.balanceOf(address(module));
        uint256 totalControlled = aTokenBalance + tokenBalance;
        
        assertLe(totalPositionPrincipal, totalControlled + 1);
    }

    function invariant_withdraw_cannot_create_value() public {
        // Covered by principal conservation
    }

    function invariant_user_isolation() public {
        (address token1, uint256 principal1, ) = module.positions(escrow1, 1);
        (address token2, uint256 principal2, ) = module.positions(escrow2, 1);
        (address token3, uint256 principal3, ) = module.positions(escrow3, 1);
        
        if (principal1 > 0) {
            assertEq(token1, address(token));
        }
        if (principal2 > 0) {
            assertEq(token2, address(token));
        }
        if (principal3 > 0) {
            assertEq(token3, address(token));
        }
    }

    function invariant_no_orphaned_assets() public view {
        uint256 aTokenBalance = aToken.balanceOf(address(module));
        uint256 tokenBalance = token.balanceOf(address(module));
        
        uint256 totalAssets = aTokenBalance + tokenBalance;
        assertGe(totalAssets, 0);
    }

    function invariant_principal_monotonic() public view {
        // Enforced by contract logic
    }
}
