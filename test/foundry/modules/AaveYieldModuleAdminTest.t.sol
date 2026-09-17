// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/interfaces/IYieldModule.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @notice Admin surface, event emissions, Ownable2Step ownership, and the
///         revocation effect for the current AaveYieldModule.
contract AaveYieldModuleAdminTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public token;
    MockAToken public aToken;

    address public owner;
    address public escrow;
    address public otherEscrow;

    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant DEPOSIT_AMOUNT = 1_000e18;

    event EscrowApproved(address indexed escrow);
    event EscrowRevoked(address indexed escrow);
    event TokenConfigured(address indexed token, address indexed aToken);
    event MinDepositConfigured(address indexed token, uint256 minDeposit);

    function setUp() public {
        owner = address(this);
        escrow = address(0x1001);
        otherEscrow = address(0x1002);

        token = new ERC20Mock('Test Token', 'TEST', owner, INITIAL_BALANCE);
        aToken = new MockAToken(address(token), 'aTest', 'aTEST');
        pool = new MockAavePool();

        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));

        module = new AaveYieldModule(address(pool));
    }

    // ============ Events ============

    function test_approveEscrow_emits() public {
        vm.expectEmit(true, true, false, false);
        emit EscrowApproved(escrow);
        module.approveEscrow(escrow);
        assertTrue(module.approvedEscrows(escrow));
    }

    function test_revokeEscrow_emits() public {
        module.approveEscrow(escrow);
        vm.expectEmit(true, true, false, false);
        emit EscrowRevoked(escrow);
        module.revokeEscrow(escrow);
        assertFalse(module.approvedEscrows(escrow));
    }

    function test_configureToken_emits() public {
        vm.expectEmit(true, true, false, false);
        emit TokenConfigured(address(token), address(aToken));
        module.configureToken(address(token), address(aToken));
        assertEq(module.tokenToAToken(address(token)), address(aToken));
    }

    function test_configureMinDeposit_emits() public {
        vm.expectEmit(true, true, false, false);
        emit MinDepositConfigured(address(token), 5e18);
        module.configureMinDeposit(address(token), 5e18);
        assertEq(module.minDepositByToken(address(token)), 5e18);
    }

    // ============ Admin is owner-only ============

    function test_admin_onlyOwner() public {
        address stranger = address(0xBAD);

        vm.startPrank(stranger);
        vm.expectRevert();
        module.approveEscrow(escrow);
        vm.expectRevert();
        module.revokeEscrow(escrow);
        vm.expectRevert();
        module.configureToken(address(token), address(aToken));
        vm.expectRevert();
        module.configureMinDeposit(address(token), 1);
        vm.stopPrank();
    }

    // ============ Token reconfiguration ============

    function test_configureToken_reconfigure_updates() public {
        MockAToken aToken2 = new MockAToken(address(token), 'aTest2', 'aTEST2');
        module.configureToken(address(token), address(aToken));
        module.configureToken(address(token), address(aToken2));
        assertEq(module.tokenToAToken(address(token)), address(aToken2));
    }

    // ============ Ownable2Step ============

    function test_ownership_twoStepTransfer() public {
        address newOwner = address(0xA11CE);

        module.transferOwnership(newOwner);
        assertEq(module.pendingOwner(), newOwner);
        assertEq(module.owner(), owner, 'owner unchanged until accepted');

        // Only the pending owner may accept.
        vm.prank(address(0xBAD));
        vm.expectRevert();
        module.acceptOwnership();

        vm.prank(newOwner);
        module.acceptOwnership();
        assertEq(module.owner(), newOwner);
        assertEq(module.pendingOwner(), address(0));

        // Old owner is no longer authorized.
        vm.expectRevert();
        module.approveEscrow(escrow);

        // New owner is authorized.
        vm.prank(newOwner);
        module.approveEscrow(escrow);
        assertTrue(module.approvedEscrows(escrow));
    }

    // ============ Revocation effect ============

    function test_revoke_blocks_initializeYield() public {
        module.approveEscrow(escrow);
        module.configureToken(address(token), address(aToken));

        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
        assertEq(accepted, DEPOSIT_AMOUNT, 'first deposit');

        module.revokeEscrow(escrow);

        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        vm.expectRevert('UnauthorizedEscrow');
        module.initializeYield(2, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
    }
}
