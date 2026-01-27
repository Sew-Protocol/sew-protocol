// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/ModuleManagementContract.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";

contract ModuleSwapExecutableTest is Test {
    EscrowVault public vault;
    ModuleManagementContract public moduleManagement;
    DefaultReleaseStrategy public releaseV1;
    DefaultReleaseStrategy public releaseV2;

    address public owner;
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");

    function setUp() public {
        owner = address(this);

        moduleManagement = new ModuleManagementContract(owner);

        // release strategies (distinct addresses; both implement IReleaseStrategy)
        releaseV1 = new DefaultReleaseStrategy();
        releaseV2 = new DefaultReleaseStrategy();

        // Minimal escrow deployment. For this test we only need module swapping paths.
        // Use dummy ops addresses; they won't be called.
        vault = new EscrowVault(
            0,
            address(0xFEE),
            address(new YieldOps(owner)),
            address(new DisputeOps(owner)),
            address(moduleManagement)
        );

        // Allow the escrow to call ModuleManagementContract (ROLE_ESCROW_CONTRACT).
        moduleManagement.registerEscrowContract(address(vault));

        // Ensure our test has timelock role on the escrow (constructor grants it to deployer).
        assertTrue(vault.hasRole(ROLE_TIMELOCK, owner));
    }

    function test_queueAndActivateDefaultReleaseStrategy_viaDirectCalls() public {
        // Default is unset.
        assertEq(moduleManagement.getModule(address(vault), BaseEscrow.ModuleType.RELEASE), address(0));

        // Queue (direct call)
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseV1));
        (address pending, uint64 eta, bool exists) = moduleManagement.getPendingModule(
            address(vault),
            BaseEscrow.ModuleType.RELEASE
        );
        assertTrue(exists);
        assertEq(pending, address(releaseV1));
        assertGt(uint256(eta), block.timestamp);

        // Activate after slow delay (7 days)
        vm.warp(block.timestamp + 7 days + 1);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        assertEq(
            moduleManagement.getModule(address(vault), BaseEscrow.ModuleType.RELEASE),
            address(releaseV1)
        );

        // Swap again (append-only new default)
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseV2));
        ( , uint64 eta2, bool exists2) = moduleManagement.getPendingModule(
            address(vault),
            BaseEscrow.ModuleType.RELEASE
        );
        assertTrue(exists2);
        vm.warp(uint256(eta2) + 1);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        assertEq(
            moduleManagement.getModule(address(vault), BaseEscrow.ModuleType.RELEASE),
            address(releaseV2)
        );
    }
}

