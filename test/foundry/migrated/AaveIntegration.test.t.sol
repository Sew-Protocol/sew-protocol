// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/modules/AaveYieldGenerationModule.sol';

contract Test_AaveIntegration is Test {
    MockAavePool pool;
    ERC20Mock token;
    MockAToken aToken;
    MockPoolAddressesProvider provider;
    AaveYieldGenerationModule aaveModule;

    address escrow = address(0xBEEF);
    address owner = address(this);

    uint256 constant INITIAL_TRANSFER = 100 ether;

    function setUp() public {
        // Deploy token and pool
        token = new ERC20Mock('Mock Token', 'MOCK', address(this), 1_000_000 ether);
        pool = new MockAavePool();

        // Deploy aToken and link to pool
        aToken = new MockAToken(address(token), 'aMock', 'aM');
        aToken.setPool(address(pool));
        pool.setAToken(address(token), address(aToken));

        // Deploy provider
        provider = new MockPoolAddressesProvider(address(pool));

        // Deploy module with this test as admin
        aaveModule = new AaveYieldGenerationModule(owner);
        // Grant timelock role to owner (this contract) so we can queue/activate
        bytes32 ROLE_TIMELOCK = aaveModule.ROLE_TIMELOCK();
        aaveModule.grantRole(ROLE_TIMELOCK, owner);

        // Queue provider and activate (Slow lane 7 days)
        aaveModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        aaveModule.activateAavePoolProvider();

        // Enable Aave
        aaveModule.setAaveEnabled(true);

        // Register token for Aave
        aaveModule.registerTokenForAave(address(token), address(aToken));

        // Fund escrow address with tokens
        token.mint(escrow, INITIAL_TRANSFER);
    }

    function test_provider_and_enable_disable() public {
        address p = address(aaveModule.aavePoolAddressesProvider());
        assertEq(p, address(provider));

        assertTrue(aaveModule.aaveEnabled());
        // disable then enable
        aaveModule.setAaveEnabled(false);
        assertFalse(aaveModule.aaveEnabled());
        aaveModule.setAaveEnabled(true);
        assertTrue(aaveModule.aaveEnabled());
    }

    function test_register_and_support() public {
        address at = aaveModule.getATokenAddress(address(token));
        assertEq(at, address(aToken));
        assertTrue(aaveModule.isTokenSupportedByAave(address(token)));
    }

    function test_deposit_to_aave_and_withdraw_on_release() public {
        uint256 workflowId = 1;
        uint256 deposit = 10 ether;

        // Approve pool to pull tokens from escrow
        vm.prank(escrow);
        token.approve(address(pool), deposit);

        // Call depositForYield as if called by escrow contract
        vm.prank(escrow);
        (bool success, uint256 aBalance) = aaveModule.depositForYield(
            workflowId,
            address(token),
            deposit
        );
        assertTrue(success);
        assertEq(aBalance, deposit);

        // Ensure escrow tracked in aave
        (bool inAave, uint256 atBal, uint256 orig) = aaveModule.getEscrowAaveData(
            escrow,
            workflowId
        );
        assertTrue(inAave);
        assertEq(atBal, deposit);
        assertEq(orig, deposit);

        // Simulate yield
        pool.simulateYield(address(token), 10);

        // Ensure pool has enough underlying to cover withdrawal: mint to pool
        token.mint(address(pool), 1000 ether);

        // Now withdraw as if escrow contract triggers a release
        vm.prank(escrow);
        (bool wsuccess, uint256 actualAmount, uint256 yieldAmount) = aaveModule.withdrawWithYield(
            workflowId,
            address(token),
            deposit
        );
        assertTrue(wsuccess);
        assertGe(actualAmount, deposit);
        assertEq(yieldAmount, actualAmount > deposit ? actualAmount - deposit : 0);

        // inAave should be false now
        (bool inAaveAfter, , ) = aaveModule.getEscrowAaveData(escrow, workflowId);
        assertFalse(inAaveAfter);
    }

    function test_calculate_yield_view() public {
        uint256 workflowId = 3;
        uint256 deposit = 30 ether;
        vm.prank(escrow);
        token.approve(address(pool), deposit);
        vm.prank(escrow);
        (bool s, uint256 aBal) = aaveModule.depositForYield(workflowId, address(token), deposit);
        assertTrue(s);

        pool.simulateYield(address(token), 100);

        // Calculate yield via module (call from escrow)
        vm.prank(escrow);
        uint256 y = aaveModule.calculateYield(workflowId, address(token));
        assertGe(y, 0);
    }
}
