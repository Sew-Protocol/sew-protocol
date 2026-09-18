// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/interfaces/IYieldModule.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @notice Admin surface, event emissions, AccessControl (Role-Based Access Control), and the
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

    /// @dev Slow-lane two-step for escrow approval. Helper is file-local to this
    ///      test suite; the module's approveEscrow/configureToken setters were
    ///      replaced by an asymmetric queue->activate (7-day) governance flow.
    function _approve(address escrow_) internal {
        module.queueApproveEscrow(escrow_);
        (, uint64 eta, ) = module.getPendingApproveEscrow();
        vm.warp(eta);
        module.activateApproveEscrow();
    }

    /// @dev Slow-lane two-step for token->aToken configuration.
    function _cfgToken(address token_, address aToken_) internal {
        module.queueConfigureToken(token_, aToken_);
        (, uint64 eta, ) = module.getPendingConfigureToken(token_);
        vm.warp(eta);
        module.activateConfigureToken(token_);
    }

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
        module.queueApproveEscrow(escrow);
        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(true, true, false, false);
        emit EscrowApproved(escrow);
        module.activateApproveEscrow();
        assertTrue(module.approvedEscrows(escrow));
    }

    function test_revokeEscrow_emits() public {
        _approve(escrow);
        vm.expectEmit(true, true, false, false);
        emit EscrowRevoked(escrow);
        module.revokeEscrow(escrow);
        assertFalse(module.approvedEscrows(escrow));
    }

    function test_configureToken_emits() public {
        module.queueConfigureToken(address(token), address(aToken));
        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(true, true, false, false);
        emit TokenConfigured(address(token), address(aToken));
        module.activateConfigureToken(address(token));
        assertEq(module.tokenToAToken(address(token)), address(aToken));
    }

    function test_configureMinDeposit_emits() public {
        vm.expectEmit(true, true, false, false);
        emit MinDepositConfigured(address(token), 5e18);
        module.configureMinDeposit(address(token), 5e18);
        assertEq(module.minDepositByToken(address(token)), 5e18);
    }

    // ============ Admin is owner-only ============

    function test_admin_onlyRoleTimelock() public {
        address stranger = address(0xBAD);

        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSignature(
                'AccessControlUnauthorizedAccount(address,bytes32)', stranger, module.ROLE_TIMELOCK()
            )
        );
        module.queueApproveEscrow(escrow);
        vm.expectRevert();
        module.revokeEscrow(escrow);
        vm.expectRevert(
            abi.encodeWithSignature(
                'AccessControlUnauthorizedAccount(address,bytes32)', stranger, module.ROLE_TIMELOCK()
            )
        );
        module.queueConfigureToken(address(token), address(aToken));
        vm.expectRevert();
        module.configureMinDeposit(address(token), 1);
        vm.stopPrank();
    }

    // ============ Token reconfiguration ============

    function test_configureToken_reconfigure_updates() public {
        MockAToken aToken2 = new MockAToken(address(token), 'aTest2', 'aTEST2');
        _cfgToken(address(token), address(aToken));
        _cfgToken(address(token), address(aToken2));
        assertEq(module.tokenToAToken(address(token)), address(aToken2));
    }

    // ============ Slow-lane asymmetry (risk-increase is slow, risk-reduce is fast) ============

    function test_activateApproveEscrow_beforeDelay_reverts() public {
        module.queueApproveEscrow(escrow);
        (address pendingValue, uint64 eta, bool exists) = module.getPendingApproveEscrow();
        assertEq(pendingValue, escrow);
        assertTrue(exists, 'pending approval recorded');
        // 1 day short of the 7-day slow-lane delay.
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(abi.encodeWithSignature('NotReady(uint64)', eta));
        module.activateApproveEscrow();
    }

    function test_activateConfigureToken_beforeDelay_reverts() public {
        module.queueConfigureToken(address(token), address(aToken));
        (address pendingValue, uint64 eta, bool exists) = module.getPendingConfigureToken(address(token));
        assertEq(pendingValue, address(aToken));
        assertTrue(exists, 'pending config recorded');
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(abi.encodeWithSignature('NotReady(uint64)', eta));
        module.activateConfigureToken(address(token));
    }

    function test_disableToken_isFast() public {
        _approve(escrow);
        _cfgToken(address(token), address(aToken));

        (bool supportedBefore, ) = module.canHandle(address(token), YieldPreset.OFF, 1000e18);
        assertTrue(supportedBefore, 'token configured before disable');

        module.disableToken(address(token));

        (bool supportedAfter, bytes32 reason) = module.canHandle(address(token), YieldPreset.OFF, 1000e18);
        assertFalse(supportedAfter, 'token disabled');
        assertEq(reason, keccak256('TOKEN_NOT_CONFIGURED'));

        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSignature('TokenNotConfigured(address)', address(token)));
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
    }

    // ============ AccessControl ============

    function test_admin_rolesGrantedToDeployer() public {
        // The module is deployed from the test contract, so address(this) holds both roles.
        assertTrue(module.hasRole(module.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(module.hasRole(module.ROLE_TIMELOCK(), address(this)));
    }

    function test_strangerCannotAdminister() public {
        address stranger = address(0xBAD);
        // startPrank so the ROLE_TIMELOCK() view call inside the revert expectation
        // does not consume the one-shot prank of the single (non-reverting) call.
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSignature(
                'AccessControlUnauthorizedAccount(address,bytes32)', stranger, module.ROLE_TIMELOCK()
            )
        );
        module.queueApproveEscrow(escrow);
        vm.stopPrank();
    }

    function test_grantedTimelockCanAdminister() public {
        // A freshly granted ROLE_TIMELOCK holder may perform admin actions.
        address newAdmin = address(0xA11CE);
        module.grantRole(module.ROLE_TIMELOCK(), newAdmin);
        assertTrue(module.hasRole(module.ROLE_TIMELOCK(), newAdmin));

        vm.prank(newAdmin);
        module.queueApproveEscrow(escrow);
        vm.warp(block.timestamp + 7 days);
        vm.prank(newAdmin);
        module.activateApproveEscrow();
        assertTrue(module.approvedEscrows(escrow));
    }

    // ============ Revocation effect ============

    function test_revoke_blocks_initializeYield() public {
        _approve(escrow);
        _cfgToken(address(token), address(aToken));

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
