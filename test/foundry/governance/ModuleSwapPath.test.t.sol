// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV1.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';
import '../../../contracts/shared/interfaces/IResolutionModule.sol';

/**
 * @title ModuleSwapPathTest
 * @notice Comprehensive tests for the full module swap migration path:
 *         IEO (DefaultResolutionModule) → DR v1 (DecentralizedResolutionModule + IncentiveModuleV1) → DR v2 (IncentiveModuleV2)
 * @dev Tests critical properties:
 *      - Module snapshots are immutable (existing escrows unaffected by swaps)
 *      - New escrows use new modules after swap
 *      - Incentive module swaps work correctly
 *      - Dispute resolution continues to work correctly after swaps
 */
contract ModuleSwapPathTest is Test {
    EscrowVault public escrow;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;
    EscrowAdminContract public adminContract;

    // IEO Module
    DefaultResolutionModule public defaultResolutionModule;
    address public ieoResolver;

    // DR v1 Modules
    DecentralizedResolutionModule public drv1ResolutionModule;
    ResolverIncentiveModuleV1 public incentiveModuleV1;
    PaymentCalculationLibraryV1 public paymentLib;

    // DR v2 Module
    ResolverIncentiveModuleV2 public incentiveModuleV2;

    // Test addresses
    address public deployer;
    address public timelock;
    address public seniorResolver;
    address public resolver1;
    address public user1;
    address public user2;

    ERC20Mock public token;

    uint256 public constant ESCROW_AMOUNT = 1000 ether;
    uint256 public constant SLOW_LANE_DELAY = 7 days;

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        ieoResolver = makeAddr('ieoResolver');
        seniorResolver = makeAddr('seniorResolver');
        resolver1 = makeAddr('resolver1');
        user1 = makeAddr('user1');
        user2 = makeAddr('user2');

        // Deploy infrastructure
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        adminContract = new EscrowAdminContract(address(this));
        escrow = new EscrowVault(100, makeAddr('feeAddress'), address(yieldOps), address(disputeOps), address(moduleManagement));

        // Grant roles
        escrow.grantRole(ROLE_TIMELOCK, timelock);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        // Deploy IEO module
        defaultResolutionModule = new DefaultResolutionModule(deployer, ieoResolver);

        // Deploy DR v1 modules
        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModuleV1 = new ResolverIncentiveModuleV1(deployer, address(paymentLib));
        drv1ResolutionModule = new DecentralizedResolutionModule(deployer);

        // Deploy DR v2 module
        incentiveModuleV2 = new ResolverIncentiveModuleV2(deployer, address(paymentLib));

        // Setup DR v1 roles
        vm.startPrank(deployer);
        incentiveModuleV1.grantRole(ROLE_TIMELOCK, timelock);
        drv1ResolutionModule.grantRole(ROLE_TIMELOCK, timelock);
        incentiveModuleV2.grantRole(ROLE_TIMELOCK, timelock);
        vm.stopPrank();

        // Deploy test token
        token = new ERC20Mock('Test Token', 'TEST', deployer, 1_000_000 ether);
        token.mint(user1, 1_000_000 ether);
        token.mint(user2, 1_000_000 ether);
    }

    // ============ Helper Functions ============

    /**
     * @notice Helper to perform slow lane module swap
     */
    function _swapResolutionModule(address newModule) internal {
        vm.prank(timelock);
        adminContract.queueResolutionModule(address(escrow), newModule);
        vm.warp(block.timestamp + SLOW_LANE_DELAY + 1);
        vm.prank(timelock);
        adminContract.activateResolutionModule(address(escrow));
    }

    /**
     * @notice Helper to setup DR v1 module (register escrow, appoint resolvers)
     */
    function _setupDRv1() internal {
        // Register escrow in DR v1 modules
        vm.startPrank(timelock);
        drv1ResolutionModule.registerEscrowContract(address(escrow));
        incentiveModuleV1.registerEscrowContract(address(escrow));
        incentiveModuleV1.registerEscrowContract(address(drv1ResolutionModule));
        incentiveModuleV2.registerEscrowContract(address(escrow));
        incentiveModuleV2.registerEscrowContract(address(drv1ResolutionModule));

        // Set incentive module in resolution module
        drv1ResolutionModule.setIncentiveModule(address(incentiveModuleV1));

        // Appoint resolvers
        drv1ResolutionModule.appointSeniorResolver(
            seniorResolver,
            'Senior Resolver',
            'Test senior resolver'
        );
        vm.stopPrank();
        vm.prank(seniorResolver);
        drv1ResolutionModule.appointResolver(resolver1, 'Resolver 1', 'Test resolver');

        // Activate resolvers
        vm.startPrank(timelock);
        drv1ResolutionModule.setResolverActive(seniorResolver, true);
        drv1ResolutionModule.setResolverActive(resolver1, true);
        drv1ResolutionModule.setResolverCapacity(seniorResolver, 0, true);
        drv1ResolutionModule.setResolverCapacity(resolver1, 0, true);
        vm.stopPrank();
    }

    /**
     * @notice Helper to create an escrow
     */
    function _createEscrow() internal returns (uint256 workflowId) {
        vm.startPrank(user1);
        token.approve(address(escrow), ESCROW_AMOUNT);
        workflowId = escrow.createEscrow(
            address(token),
            user2,
            ESCROW_AMOUNT,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();
        return workflowId;
    }

}
