// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/ops/YieldOps.sol';
import 'contracts/ops/DisputeOps.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/token/SewToken.sol';
import 'contracts/core/EscrowableERC20.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/modules/DefaultReleaseStrategy.sol';
import 'contracts/core/modules/DefaultResolutionModule.sol';
import 'contracts/modules/DefaultYieldDistributionModule.sol';

contract Test_MainnetReleaseSequence_test is Test {
    SewToken public governanceToken;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowableERC20 public escrowable;
    EscrowVault public vault;
    DefaultReleaseStrategy public relStrat;
    DefaultResolutionModule public resModule;
    DefaultYieldDistributionModule public yieldDist;

    address deployer = address(this);
    address multisig = address(0xAB);
    address resolver = address(0xCD);
    address feeAddress = address(0xE1);

    uint256 constant INITIAL_TOKEN_SUPPLY = 10_000_000 ether;

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        // Deploy governance token
        governanceToken = new SewToken('Sew Token', 'SEW', deployer, INITIAL_TOKEN_SUPPLY);

        // Deploy modules
        relStrat = new DefaultReleaseStrategy();
        resModule = new DefaultResolutionModule(deployer, resolver);
        yieldDist = new DefaultYieldDistributionModule();

        // Deploy main contracts
        escrowable = new EscrowableERC20(
            'Escrowable Token',
            'EUSD',
            100,
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
        vault = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
    }

    function test_stage0_and_stage1_deployments_and_role_transfers() public {
        // Distribute governance tokens and delegate
        address tokenHolder1 = address(0x11);
        address tokenHolder2 = address(0x12);
        address tokenHolder3 = address(0x13);
        governanceToken.transfer(tokenHolder1, 1_000_000 ether);
        governanceToken.transfer(tokenHolder2, 2_000_000 ether);
        governanceToken.transfer(tokenHolder3, 3_000_000 ether);

        // Delegation (ERC20Votes)
        vm.prank(tokenHolder1);
        governanceToken.delegate(tokenHolder1);
        vm.prank(tokenHolder2);
        governanceToken.delegate(tokenHolder2);
        vm.prank(tokenHolder3);
        governanceToken.delegate(tokenHolder3);

        assertEq(governanceToken.balanceOf(tokenHolder1), 1_000_000 ether);
        assertEq(governanceToken.balanceOf(tokenHolder2), 2_000_000 ether);
        assertEq(governanceToken.balanceOf(tokenHolder3), 3_000_000 ether);

        // Verify modules are deployed and have expected metadata
        assertEq(relStrat.strategyName(), 'DefaultBuyerRelease');
        assertEq(resModule.moduleName(), 'DefaultSingleResolver');
        assertEq(yieldDist.moduleName(), 'DefaultYieldDistribution');

        // Verify deployer has admin roles on escrow contracts
        bytes32 ADMIN = escrowable.DEFAULT_ADMIN_ROLE();
        bytes32 ROLE_TIMELOCK = escrowable.ROLE_TIMELOCK();
        assertTrue(escrowable.hasRole(ADMIN, deployer));
        assertTrue(vault.hasRole(ADMIN, deployer));

        // Transfer roles to multisig (simulate Safe)
        escrowable.grantRole(ADMIN, multisig);
        escrowable.grantRole(ROLE_TIMELOCK, multisig);
        vault.grantRole(ADMIN, multisig);
        vault.grantRole(ROLE_TIMELOCK, multisig);

        // Revoke deployer admin
        escrowable.revokeRole(ADMIN, deployer);
        vault.revokeRole(ADMIN, deployer);

        assertTrue(escrowable.hasRole(ADMIN, multisig));
        assertTrue(vault.hasRole(ADMIN, multisig));
        assertFalse(escrowable.hasRole(ADMIN, deployer));
        assertFalse(vault.hasRole(ADMIN, deployer));
    }
}
