// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/core/L2AddressRegistry.sol';
import '../../../contracts/core/RPCEndpointManager.sol';
import '../../../contracts/core/MultiL2ModuleCoordinator.sol';

/// @notice Target tests for the self-contained L2 state-machine contracts:
///         L2AddressRegistry, RPCEndpointManager, MultiL2ModuleCoordinator.
contract L2AddressRegistryTest is Test {
    L2AddressRegistry public reg;
    address public g1 = address(0xA1);
    address public g2 = address(0xA2);
    address public g3 = address(0xA3);
    address public outsider = address(0xB0);

    function setUp() public {
        address[] memory g = new address[](3);
        g[0] = g1;
        g[1] = g2;
        g[2] = g3;
        reg = new L2AddressRegistry(g, 2);
    }

    function test_constructor() public {
        assertEq(reg.governorCount(), 3);
        assertEq(reg.requiredSignatures(), 2);
        assertTrue(reg.isGovernor(g1));
        assertFalse(reg.isGovernor(outsider));
        // Required > available reverts
        address[] memory g = new address[](1);
        g[0] = g1;
        vm.expectRevert();
        new L2AddressRegistry(g, 2);
    }

    function test_registerContract_onlyGovernor() public {
        vm.prank(g1);
        reg.registerContract('EscrowVault');
        assertTrue(reg.isRegisteredContract('EscrowVault'));
        assertEq(reg.getContractNames().length, 1);
        assertEq(reg.getContractNames()[0], 'EscrowVault');
    }

    function test_registerContract_unauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(L2AddressRegistry.NotGovernor.selector, outsider));
        reg.registerContract('EscrowVault');
    }

    function test_registerContract_duplicate() public {
        vm.startPrank(g1);
        reg.registerContract('EscrowVault');
        vm.expectRevert(abi.encodeWithSelector(L2AddressRegistry.ContractAlreadyRegistered.selector, 'EscrowVault'));
        reg.registerContract('EscrowVault');
        vm.stopPrank();
    }

    function test_registerAndActivateAddress() public {
        address vault = address(0xC0FFEE);
        vm.startPrank(g1);
        reg.registerContract('EscrowVault');
        reg.registerAddress(1, 'EscrowVault', 'v1', vault);
        reg.activateVersion(1, 'EscrowVault', 'v1');
        vm.stopPrank();

        (address addr, string memory version) = reg.getAddress(1, 'EscrowVault');
        assertEq(addr, vault);
        assertEq(version, 'v1');
        assertEq(reg.getAddressVersion(1, 'EscrowVault', 'v1'), vault);
    }

    function test_registerAddress_notRegisteredContract() public {
        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(L2AddressRegistry.ContractNotRegistered.selector, 'EscrowVault'));
        reg.registerAddress(1, 'EscrowVault', 'v1', address(0x1));
    }

    function test_getAddress_notActivated() public {
        vm.startPrank(g1);
        reg.registerContract('EscrowVault');
        reg.registerAddress(1, 'EscrowVault', 'v1', address(0xC0FFEE));
        vm.stopPrank();
        vm.expectRevert();
        reg.getAddress(1, 'EscrowVault');
    }

    function test_multisigUpdate_autoExecuteAtThreshold() public {
        address newVault = address(0xDD);
        vm.startPrank(g1);
        reg.registerContract('EscrowVault');
        reg.registerAddress(1, 'EscrowVault', 'v1', address(0x1));
        reg.activateVersion(1, 'EscrowVault', 'v1');
        bytes32 id = reg.proposeUpdate(1, 'EscrowVault', newVault);
        vm.stopPrank();

        // First approval only increments count; second reaches threshold (2) and auto-executes.
        vm.prank(g2);
        reg.approveUpdate(id);
        (, , , , uint256 approvalsAfterFirst, , ) = reg.pendingUpdates(id);
        assertEq(approvalsAfterFirst, 1);

        vm.prank(g3);
        vm.expectEmit();
        emit L2AddressRegistry.UpdateExecuted(id, 1, 'EscrowVault', newVault);
        reg.approveUpdate(id);

        (address addr, string memory version) = reg.getAddress(1, 'EscrowVault');
        assertEq(addr, newVault);
        assertEq(version, 'v2'); // version bumped from v1 -> v2
        (, , , , , bool executed, ) = reg.pendingUpdates(id);
        assertTrue(executed);
    }

    function test_proposeUpdate_unauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(L2AddressRegistry.NotGovernor.selector, outsider));
        reg.proposeUpdate(1, 'EscrowVault', address(0x1));
    }

    function test_executeUpdate_insufficientApprovals() public {
        address newVault = address(0xDD);
        vm.startPrank(g1);
        reg.registerContract('EscrowVault');
        bytes32 id = reg.proposeUpdate(1, 'EscrowVault', newVault);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(L2AddressRegistry.InsufficientApprovals.selector, id));
        reg.executeUpdate(id);
    }

    function test_duplicateApproval() public {
        address newVault = address(0xDD);
        vm.startPrank(g1);
        reg.registerContract('EscrowVault');
        bytes32 id = reg.proposeUpdate(1, 'EscrowVault', newVault);
        vm.stopPrank();

        vm.prank(g2);
        reg.approveUpdate(id);
        vm.prank(g2);
        vm.expectRevert(abi.encodeWithSelector(L2AddressRegistry.DuplicateApproval.selector, id, g2));
        reg.approveUpdate(id);
    }

    function test_executeUpdate_alreadyExecuted() public {
        address newVault = address(0xDD);
        vm.startPrank(g1);
        reg.registerContract('EscrowVault');
        bytes32 id = reg.proposeUpdate(1, 'EscrowVault', newVault);
        vm.stopPrank();
        vm.prank(g2);
        reg.approveUpdate(id);
        vm.prank(g3);
        reg.approveUpdate(id); // auto-executes

        vm.expectRevert(abi.encodeWithSelector(L2AddressRegistry.UpdateAlreadyExecuted.selector, id));
        reg.executeUpdate(id);
    }
}

contract RPCEndpointManagerTest is Test {
    RPCEndpointManager public mgr;
    address public m1 = address(0xD1);
    address public m2 = address(0xD2);
    address public outsider = address(0xE0);

    function setUp() public {
        address[] memory m = new address[](2);
        m[0] = m1;
        m[1] = m2;
        mgr = new RPCEndpointManager(m);
    }

    function test_constructor() public {
        assertEq(mgr.managerCount(), 2);
        assertTrue(mgr.isManager(m1));
        assertFalse(mgr.isManager(outsider));
    }

    function test_setPrimaryEndpoint() public {
        vm.prank(m1);
        mgr.setPrimaryEndpoint(1, 'https://eth.rpc', 100);
        (string memory endpoint, bool isPrimary) = mgr.getActiveEndpoint(1);
        assertEq(endpoint, 'https://eth.rpc');
        assertTrue(isPrimary);
        assertTrue(mgr.isHealthy(1));
    }

    function test_setEndpoint_unauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RPCEndpointManager.NotManager.selector, outsider));
        mgr.setPrimaryEndpoint(1, 'https://eth.rpc', 100);
    }

    function test_setPrimaryEndpoint_rateLimitTooHigh() public {
        vm.prank(m1);
        vm.expectRevert('RateLimitTooHigh');
        mgr.setPrimaryEndpoint(1, 'https://eth.rpc', 10001);
    }

    function test_failoverToBackupAfterThreeFailures() public {
        vm.startPrank(m1);
        mgr.setPrimaryEndpoint(1, 'https://primary', 100);
        mgr.setBackupEndpoint(1, 'https://backup', 100);
        vm.stopPrank();

        // 3 failures -> primary unhealthy -> active endpoint becomes backup
        vm.prank(m2);
        mgr.recordFailure(1);
        vm.prank(m2);
        mgr.recordFailure(1);
        vm.prank(m2);
        mgr.recordFailure(1);

        assertFalse(mgr.isHealthy(1));
        (string memory endpoint, bool isPrimary) = mgr.getActiveEndpoint(1);
        assertEq(endpoint, 'https://backup');
        assertFalse(isPrimary);
    }

    function test_successResetsFailureCount() public {
        vm.startPrank(m1);
        mgr.setPrimaryEndpoint(1, 'https://primary', 100);
        mgr.recordFailure(1);
        mgr.recordFailure(1);
        mgr.recordSuccess(1);
        mgr.recordSuccess(1); // second success fully clears the counter
        vm.stopPrank();
        (bool working, uint256 failureCount, , ) = mgr.getHealthStatus(1);
        assertTrue(working);
        assertEq(failureCount, 0);
    }

    function test_resetHealth() public {
        vm.startPrank(m1);
        mgr.setPrimaryEndpoint(1, 'https://primary', 100);
        mgr.recordFailure(1);
        mgr.recordFailure(1);
        mgr.recordFailure(1);
        mgr.resetHealth(1);
        vm.stopPrank();
        (bool working, uint256 failureCount, , ) = mgr.getHealthStatus(1);
        assertTrue(working);
        assertEq(failureCount, 0);
    }

    function test_disablePrimaryFallsBackToBackup() public {
        vm.startPrank(m1);
        mgr.setPrimaryEndpoint(1, 'https://primary', 100);
        mgr.setBackupEndpoint(1, 'https://backup', 100);
        mgr.disableEndpoint(1, true);
        vm.stopPrank();
        (string memory endpoint, bool isPrimary) = mgr.getActiveEndpoint(1);
        assertEq(endpoint, 'https://backup');
        assertFalse(isPrimary);
    }

    function test_addRemoveManager() public {
        address m3 = address(0xD3);
        vm.prank(m1);
        mgr.addManager(m3);
        assertTrue(mgr.isManager(m3));
        assertEq(mgr.managerCount(), 3);

        vm.prank(m3);
        mgr.removeManager(m1);
        assertFalse(mgr.isManager(m1));
        assertEq(mgr.managerCount(), 2);
    }

    function test_removeLastManagerForbidden() public {
        vm.startPrank(m1);
        mgr.removeManager(m2); // now only m1 remains (count = 1)
        vm.expectRevert('CannotRemoveLastManager');
        mgr.removeManager(m1);
        vm.stopPrank();
    }
}

contract MultiL2ModuleCoordinatorTest is Test {
    MultiL2ModuleCoordinator public coord;
    address public a1 = address(0xF1);
    address public a2 = address(0xF2);
    address public outsider = address(0x99);

    function setUp() public {
        address[] memory a = new address[](2);
        a[0] = a1;
        a[1] = a2;
        coord = new MultiL2ModuleCoordinator(a);
    }

    function test_constructor() public {
        assertEq(coord.authorizedCount(), 2);
        assertTrue(coord.isAuthorized(a1));
        assertFalse(coord.isAuthorized(outsider));
        uint256[] memory chains = coord.getSupportedChains();
        assertEq(chains.length, 4);
    }

    function test_queueModuleUpdate() public {
        vm.prank(a1);
        bytes32 id = coord.queueModuleUpdate(address(0xCAFE), bytes4(0x12345678), 'yield upgrade');
        (, , , MultiL2ModuleCoordinator.ModuleUpdate memory u) = coord.getActivationStatus(id);
        assertEq(u.module, address(0xCAFE));
        assertEq(u.activateAfter, u.queuedAt + coord.MIN_ACTIVATION_DELAY());
        assertEq(u.chainsMask, 0xF); // 4 supported chains
        assertFalse(u.completed);
    }

    function test_queueModuleUpdate_unauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(MultiL2ModuleCoordinator.NotAuthorized.selector, outsider));
        coord.queueModuleUpdate(address(0xCAFE), bytes4(0), 'x');
    }

    function test_queueModuleUpdate_zeroModule() public {
        vm.prank(a1);
        vm.expectRevert('InvalidModule');
        coord.queueModuleUpdate(address(0), bytes4(0), 'x');
    }

    function test_recordActivation_requiresDelay() public {
        vm.prank(a1);
        bytes32 id = coord.queueModuleUpdate(address(0xCAFE), bytes4(0), 'x');
        // Before delay elapses -> not ready
        vm.expectRevert(abi.encodeWithSelector(MultiL2ModuleCoordinator.UpdateNotReady.selector, id, uint64(block.timestamp) + coord.MIN_ACTIVATION_DELAY()));
        vm.prank(a2);
        coord.recordActivation(id, 1, bytes32(0), 'ok');
    }

    function test_recordActivation_allChainsCompletesUpdate() public {
        vm.prank(a1);
        bytes32 id = coord.queueModuleUpdate(address(0xCAFE), bytes4(0), 'x');
        vm.warp(block.timestamp + coord.MIN_ACTIVATION_DELAY());

        uint256[] memory chains = coord.getSupportedChains();
        for (uint256 i = 0; i < chains.length; i++) {
            vm.prank(a2);
            coord.recordActivation(id, chains[i], bytes32(uint256(0x100 + i)), 'ok');
        }

        (bool completed, uint256 activatedCount, uint256 totalChains, ) = coord.getActivationStatus(id);
        assertTrue(completed);
        assertEq(activatedCount, 4);
        assertEq(totalChains, 4);
        // Completed updates are excluded from pending list
        assertEq(coord.getPendingUpdates().length, 0);
    }

    function test_recordActivation_unsupportedChain() public {
        vm.prank(a1);
        bytes32 id = coord.queueModuleUpdate(address(0xCAFE), bytes4(0), 'x');
        vm.warp(block.timestamp + coord.MIN_ACTIVATION_DELAY());
        vm.prank(a2);
        vm.expectRevert(abi.encodeWithSelector(MultiL2ModuleCoordinator.ChainNotSupported.selector, 999));
        coord.recordActivation(id, 999, bytes32(0), 'x');
    }

    function test_recordActivation_alreadyActivated() public {
        vm.prank(a1);
        bytes32 id = coord.queueModuleUpdate(address(0xCAFE), bytes4(0), 'x');
        vm.warp(block.timestamp + coord.MIN_ACTIVATION_DELAY());
        vm.startPrank(a2);
        coord.recordActivation(id, 1, bytes32(0), 'ok');
        vm.expectRevert(abi.encodeWithSelector(MultiL2ModuleCoordinator.AlreadyActivated.selector, id, uint256(1)));
        coord.recordActivation(id, 1, bytes32(0), 'dup');
        vm.stopPrank();
    }

    function test_recordActivation_updateNotFound() public {
        vm.warp(block.timestamp + coord.MIN_ACTIVATION_DELAY());
        vm.prank(a2);
        vm.expectRevert(abi.encodeWithSelector(MultiL2ModuleCoordinator.UpdateNotFound.selector, bytes32(uint256(0xBAD))));
        coord.recordActivation(bytes32(uint256(0xBAD)), 1, bytes32(0), 'x');
    }

    function test_recordActivationFailure() public {
        vm.prank(a1);
        bytes32 id = coord.queueModuleUpdate(address(0xCAFE), bytes4(0), 'x');
        vm.prank(a2);
        vm.expectEmit();
        emit MultiL2ModuleCoordinator.ChainActivationFailed(id, 1, 'rpc down');
        coord.recordActivationFailure(id, 1, 'rpc down');
    }

    function test_isReady() public {
        vm.prank(a1);
        bytes32 id = coord.queueModuleUpdate(address(0xCAFE), bytes4(0), 'x');
        (bool ready, uint64 readyAt) = coord.isReady(id);
        assertFalse(ready);
        vm.warp(readyAt + 1);
        (ready, ) = coord.isReady(id);
        assertTrue(ready);
    }

    function test_addRemoveAuthorizer() public {
        address a3 = address(0xF3);
        vm.prank(a1);
        coord.addAuthorizer(a3);
        assertTrue(coord.isAuthorized(a3));
        assertEq(coord.authorizedCount(), 3);

        vm.prank(a3);
        coord.removeAuthorizer(a1);
        assertFalse(coord.isAuthorized(a1));
        assertEq(coord.authorizedCount(), 2);
    }
}
