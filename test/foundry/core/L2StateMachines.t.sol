// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/core/L2AddressRegistry.sol';

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
