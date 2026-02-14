// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/AaveYieldModule.sol';
import '../../../contracts/mocks/MockAavePool.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

contract AaveYieldInterTemporalBug is Test {
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

    function test_Reproduction_InterTemporalYieldBug() public {
        uint256 amount = 100e18;

        // 1. Escrow 1 deposits 100 tokens when index is 1.0
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount, escrow);

        // 2. Index increases to 2.0 (100% yield)
        pool.simulateYield(address(token), 100); // This mock increases index by YIELD_RATE (1e25 = 1%) per block
        // Wait, simulateYield logic in MockAavePool was slightly different.
        // liquidityIndex[token] = index + (index * YIELD_RATE * blocks) / INITIAL_LIQUIDITY_INDEX;
        // If blocks = 100, index = 1e27 + (1e27 * 1e25 * 100) / 1e27 = 1e27 + 1e27 = 2e27. Perfect.

        assertEq(pool.getLiquidityIndex(address(token)), 2e27);
        // Escrow 1 current value should be 200e18
        assertEq(aToken.balanceOf(address(module)), 200e18);

        // 3. Escrow 2 deposits 100 tokens when index is 2.0
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(2, address(token), amount, escrow);

        // Total underlying in module should be 300e18 (200 from E1, 100 from E2)
        assertEq(aToken.balanceOf(address(module)), 300e18);

        // 4. Check reported yield for both
        vm.prank(escrow);
        uint256 yield1 = module.calculateYield(1, address(token), escrow);
        vm.prank(escrow);
        uint256 yield2 = module.calculateYield(2, address(token), escrow);

        console.log("Yield 1 reported:", yield1);
        console.log("Yield 2 reported:", yield2);

        // EXPECTED:
        // Escrow 1: 100e18 yield (value 200e18 - deposit 100e18)
        // Escrow 2: 0 yield (value 100e18 - deposit 100e18)

        // Fix: Each escrow should report its own yield correctly
        assertEq(yield1, 100e18, "Fix: yield1 should be 100e18");
        assertEq(yield2, 0, "Fix: yield2 should be 0");
    }
}
