// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/AaveYieldModule.sol';
import '../../../contracts/mocks/MockAavePool.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

contract AaveYieldBugReproduction is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    MockPoolAddressesProvider public provider;
    ERC20Mock public token;
    MockAToken public aToken;

    address public owner;
    address public timelock;
    address public escrow = address(0x3);

    function setUp() public {
        owner = address(this);
        timelock = address(0x1);

        token = new ERC20Mock("Test", "TEST", address(this), 1000000e18);
        aToken = new MockAToken(address(token), "aTest", "aTEST");
        pool = new MockAavePool();
        provider = new MockPoolAddressesProvider(address(pool));

        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));

        module = new AaveYieldModule(owner);
        module.grantRole(module.ROLE_TIMELOCK(), timelock);
        
        vm.startPrank(timelock);
        module.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        module.activateAavePoolProvider();
        module.registerTokenForAave(address(token), address(aToken));
        module.setAaveEnabled(true);
        vm.stopPrank();

        module.grantRole(module.ROLE_ESCROW_CONTRACT(), escrow);
    }

    function test_Reproduction_CalculateYield_InflationBug() public {
        uint256 amount1 = 100e18;
        uint256 amount2 = 100e18;

        // Escrow 1 deposits
        token.mint(escrow, amount1);
        vm.prank(escrow);
        token.approve(address(module), amount1);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount1, escrow);

        // Escrow 2 deposits
        token.mint(escrow, amount2);
        vm.prank(escrow);
        token.approve(address(module), amount2);
        vm.prank(escrow);
        module.depositForYield(2, address(token), amount2, escrow);

        // No interest accrued yet. Yield for both should be 0.
        vm.prank(escrow);
        uint256 yield1 = module.calculateYield(1, address(token), escrow);
        vm.prank(escrow);
        uint256 yield2 = module.calculateYield(2, address(token), escrow);

        console.log("Yield 1 reported:", yield1);
        console.log("Yield 2 reported:", yield2);

        // With the fix, yield should be 0 because it correctly uses totalTrackedATokenBalance
        assertEq(yield1, 0, "Fix: yield1 should be 0");
        assertEq(yield2, 0, "Fix: yield2 should be 0");
    }

    function test_Reproduction_WorkflowIdCollisionBug() public {
        address escrow2 = address(0x4);
        module.grantRole(module.ROLE_ESCROW_CONTRACT(), escrow2);

        uint256 amount = 100e18;
        uint256 wid = 1; // Same ID for both

        // Escrow 1 deposits
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(wid, address(token), amount, escrow);

        // Escrow 2 deposits with same ID
        token.mint(escrow2, amount);
        vm.prank(escrow2);
        token.approve(address(module), amount);
        vm.prank(escrow2);
        module.depositForYield(wid, address(token), amount, escrow2);

        // Now if Escrow 1 tries to withdraw, it will use escrowContract parameter correctly.
        
        vm.prank(escrow);
        (, uint256 actual, ) = module.withdrawWithYield(wid, address(token), amount, escrow);
        
        // It should have withdrawn for escrow 1, but it might have withdrawn for escrow 2
        // Or if we check escrowInAave for escrow 1, it should be false now if it worked.
        (bool inAave1, , ) = module.getEscrowAaveData(escrow, wid);
        (bool inAave2, , ) = module.getEscrowAaveData(escrow2, wid);

        console.log("Escrow 1 still in Aave:", inAave1);
        console.log("Escrow 2 still in Aave:", inAave2);

        // With the fix, we expect Escrow 1 to be cleared and Escrow 2 to remain
        assertFalse(inAave1, "Fix: Escrow 1 state should be cleared");
        assertTrue(inAave2, "Fix: Escrow 2 state should NOT be cleared");
    }
}
