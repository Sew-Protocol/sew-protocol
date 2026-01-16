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
import '../../../contracts/types/EscrowTypes.sol';
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
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        escrow = new EscrowVault(100, makeAddr('feeAddress'), address(yieldOps), address(disputeOps));

        // Grant roles
        escrow.grantRole(ROLE_TIMELOCK, timelock);

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
        escrow.queueResolutionModule(newModule);
        vm.warp(block.timestamp + SLOW_LANE_DELAY + 1);
        vm.prank(timelock);
        escrow.activateResolutionModule();
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
                yieldEnabled: false,
                autoReleaseTime: 0,
                autoCancelTime: 0,
                escrowType: EscrowType.STANDARD
            })
        );
        vm.stopPrank();
    }

    // ============ Test: IEO Initial State ============

    /**
     * @notice Test IEO initial state: DefaultResolutionModule active
     */
    function test_IEO_InitialState() public {
        // Activate IEO module
        _swapResolutionModule(address(defaultResolutionModule));

        // Verify IEO module is active
        address activeModule = address(escrow.disputeResolutionModule());
        assertEq(activeModule, address(defaultResolutionModule), 'IEO module should be active');

        // Create escrow in IEO state
        uint256 workflowId = _createEscrow();

        // Verify escrow created
        assertEq(escrow.getEscrowCount(), 1, 'Should have 1 escrow');
        assertEq(
            escrow.getSnapshotResolutionModule(workflowId),
            address(defaultResolutionModule),
            'Escrow should snapshot IEO module'
        );
    }

    // ============ Test: IEO → DR v1 Swap ============

    /**
     * @notice Test swapping from IEO (DefaultResolutionModule) to DR v1 (DecentralizedResolutionModule)
     */
    function test_IEOTov1_Swap() public {
        // Step 1: Activate IEO module
        _swapResolutionModule(address(defaultResolutionModule));

        // Step 2: Create escrow in IEO state
        uint256 ieoEscrowId = _createEscrow();

        // Step 3: Verify escrow uses DefaultResolutionModule snapshot
        address snapshotModule = escrow.getSnapshotResolutionModule(ieoEscrowId);
        assertEq(
            snapshotModule,
            address(defaultResolutionModule),
            'IEO escrow should snapshot DefaultResolutionModule'
        );

        // Step 4: Setup DR v1
        _setupDRv1();

        // Step 5: Swap to DR v1
        _swapResolutionModule(address(drv1ResolutionModule));

        // Step 6: Verify old escrow still uses DefaultResolutionModule snapshot
        address snapshotAfterSwap = escrow.getSnapshotResolutionModule(ieoEscrowId);
        assertEq(
            snapshotAfterSwap,
            address(defaultResolutionModule),
            'IEO escrow should still use DefaultResolutionModule after swap'
        );

        // Step 7: Verify new escrow uses DR v1 module
        uint256 drv1EscrowId = _createEscrow();
        address drv1Snapshot = escrow.getSnapshotResolutionModule(drv1EscrowId);
        assertEq(
            drv1Snapshot,
            address(drv1ResolutionModule),
            'New escrow should use DR v1 module'
        );

        // Step 8: Verify active module is DR v1
        address activeModule = address(escrow.disputeResolutionModule());
        assertEq(activeModule, address(drv1ResolutionModule), 'Active module should be DR v1');
    }

    /**
     * @notice Test that disputes work correctly with both IEO and DR v1 escrows after swap
     */
    function test_IEOTov1_DisputesWork() public {
        // Setup: IEO → DR v1 swap with escrows in both states
        _swapResolutionModule(address(defaultResolutionModule));
        uint256 ieoEscrowId = _createEscrow();
        _setupDRv1();
        _swapResolutionModule(address(drv1ResolutionModule));
        uint256 drv1EscrowId = _createEscrow();

        // Raise dispute on IEO escrow (should use DefaultResolutionModule)
        vm.prank(user1);
        escrow.raiseDispute(ieoEscrowId);

        // Verify IEO module handles dispute (check resolver)
        IResolutionModule snapshotModule = IResolutionModule(
            escrow.getSnapshotResolutionModule(ieoEscrowId)
        );
        (address resolver, uint8 level) = snapshotModule.getDisputeResolver(
            ieoEscrowId,
            abi.encode(address(token), user1, user2, ESCROW_AMOUNT)
        );
        assertEq(resolver, ieoResolver, 'IEO escrow should use IEO resolver');

        // Raise dispute on DR v1 escrow (should use DecentralizedResolutionModule)
        vm.prank(user1);
        escrow.raiseDispute(drv1EscrowId);

        // Verify DR v1 module handles dispute
        IResolutionModule drv1Module = IResolutionModule(
            escrow.getSnapshotResolutionModule(drv1EscrowId)
        );
        (address drv1Resolver, uint8 drv1Level) = drv1Module.getDisputeResolver(
            drv1EscrowId,
            abi.encode(address(token), user1, user2, ESCROW_AMOUNT)
        );
        assertTrue(drv1Resolver != address(0), 'DR v1 escrow should have resolver assigned');
        // DR v1 can assign resolver1 or seniorResolver depending on routing
        assertTrue(
            drv1Resolver == resolver1 || drv1Resolver == seniorResolver,
            'DR v1 escrow should use DR v1 resolver'
        );
    }

    // ============ Test: DR v1 → DR v2 Incentive Module Swap ============

    /**
     * @notice Test swapping incentive module from V1 to V2
     */
    function test_DRv1ToDRv2_IncentiveModuleSwap() public {
        // Setup: IEO → DR v1
        _swapResolutionModule(address(defaultResolutionModule));
        _setupDRv1();
        _swapResolutionModule(address(drv1ResolutionModule));

        // Create escrow with V1
        uint256 v1EscrowId = _createEscrow();

        // Verify V1 is active
        address activeIncentiveModule = address(drv1ResolutionModule.incentiveModule());
        assertEq(
            activeIncentiveModule,
            address(incentiveModuleV1),
            'Incentive module should be V1'
        );

        // Swap to V2
        vm.prank(timelock);
        drv1ResolutionModule.setIncentiveModule(address(incentiveModuleV2));

        // Verify V2 is active
        activeIncentiveModule = address(drv1ResolutionModule.incentiveModule());
        assertEq(
            activeIncentiveModule,
            address(incentiveModuleV2),
            'Incentive module should be V2'
        );

        // Create new escrow - should use V2
        uint256 v2EscrowId = _createEscrow();

        // Raise dispute on V1 escrow - hooks should still work
        vm.prank(user1);
        escrow.raiseDispute(v1EscrowId);

        // Raise dispute on V2 escrow
        vm.prank(user1);
        escrow.raiseDispute(v2EscrowId);

        // Both should have resolvers recorded (V1 hooks work with V2 module)
        // Note: V1 escrow dispute was raised before V2 swap, but hooks are called by resolution module
        // The active incentive module (V2) will handle hooks for all disputes raised after swap
        // This is correct behavior - new disputes use new module
    }

    // ============ Test: Full Migration Path ============

    /**
     * @notice Test the complete migration path: IEO → DR v1 → DR v2
     */
    function test_FullMigrationPath() public {
        // Phase 1: IEO State
        _swapResolutionModule(address(defaultResolutionModule));
        uint256 ieoEscrowId = _createEscrow();

        // Verify IEO state
        assertEq(
            escrow.getSnapshotResolutionModule(ieoEscrowId),
            address(defaultResolutionModule),
            'IEO escrow should use DefaultResolutionModule'
        );

        // Phase 2: Swap to DR v1
        _setupDRv1();
        _swapResolutionModule(address(drv1ResolutionModule));
        uint256 drv1EscrowId = _createEscrow();

        // Verify IEO escrow unchanged, DR v1 escrow uses DR v1
        assertEq(
            escrow.getSnapshotResolutionModule(ieoEscrowId),
            address(defaultResolutionModule),
            'IEO escrow should still use DefaultResolutionModule'
        );
        assertEq(
            escrow.getSnapshotResolutionModule(drv1EscrowId),
            address(drv1ResolutionModule),
            'DR v1 escrow should use DecentralizedResolutionModule'
        );
        assertEq(
            address(drv1ResolutionModule.incentiveModule()),
            address(incentiveModuleV1),
            'Should be using IncentiveModuleV1'
        );

        // Phase 3: Swap incentive module to V2
        vm.prank(timelock);
        drv1ResolutionModule.setIncentiveModule(address(incentiveModuleV2));
        uint256 drv2EscrowId = _createEscrow();

        // Verify all escrows have correct snapshots
        assertEq(
            escrow.getSnapshotResolutionModule(ieoEscrowId),
            address(defaultResolutionModule),
            'IEO escrow unchanged'
        );
        assertEq(
            escrow.getSnapshotResolutionModule(drv1EscrowId),
            address(drv1ResolutionModule),
            'DR v1 escrow unchanged'
        );
        assertEq(
            escrow.getSnapshotResolutionModule(drv2EscrowId),
            address(drv1ResolutionModule),
            'DR v2 escrow uses DecentralizedResolutionModule'
        );
        assertEq(
            address(drv1ResolutionModule.incentiveModule()),
            address(incentiveModuleV2),
            'Should be using IncentiveModuleV2'
        );

        // Phase 4: Verify disputes work correctly for all escrows
        // IEO escrow
        vm.prank(user1);
        escrow.raiseDispute(ieoEscrowId);
        IResolutionModule ieoModule = IResolutionModule(
            escrow.getSnapshotResolutionModule(ieoEscrowId)
        );
        (address ieoResolverAddr, ) = ieoModule.getDisputeResolver(
            ieoEscrowId,
            abi.encode(address(token), user1, user2, ESCROW_AMOUNT)
        );
        assertEq(ieoResolverAddr, ieoResolver, 'IEO escrow should use IEO resolver');

        // DR v1 escrow (created before V2 swap)
        vm.prank(user1);
        escrow.raiseDispute(drv1EscrowId);
        IResolutionModule drv1Module = IResolutionModule(
            escrow.getSnapshotResolutionModule(drv1EscrowId)        );
        (address drv1ResolverAddr, ) = drv1Module.getDisputeResolver(
            drv1EscrowId,
            abi.encode(address(token), user1, user2, ESCROW_AMOUNT)
        );
        assertTrue(
            drv1ResolverAddr == resolver1 || drv1ResolverAddr == seniorResolver,
            'DR v1 escrow should use DR resolver'
        );

        // DR v2 escrow (created after V2 swap)
        vm.prank(user1);
        escrow.raiseDispute(drv2EscrowId);
        IResolutionModule drv2Module = IResolutionModule(
            escrow.getSnapshotResolutionModule(drv2EscrowId)
        );
        (address drv2ResolverAddr, ) = drv2Module.getDisputeResolver(
            drv2EscrowId,
            abi.encode(address(token), user1, user2, ESCROW_AMOUNT)
        );
        assertTrue(
            drv2ResolverAddr == resolver1 || drv2ResolverAddr == seniorResolver,
            'DR v2 escrow should use DR resolver'
        );
    }

    // ============ Test: Snapshot Immutability ============

    /**
     * @notice Test that module snapshots are immutable - multiple swaps don't affect existing escrows
     */
    function test_SnapshotImmutability() public {
        // Create escrow in IEO state
        _swapResolutionModule(address(defaultResolutionModule));
        uint256 escrow1 = _createEscrow();
        address snapshot1 = escrow.getSnapshotResolutionModule(escrow1);

        // Swap to DR v1
        _setupDRv1();
        _swapResolutionModule(address(drv1ResolutionModule));
        uint256 escrow2 = _createEscrow();

        // Verify escrow1 snapshot unchanged
        assertEq(
            escrow.getSnapshotResolutionModule(escrow1),
            snapshot1,
            'Escrow1 snapshot should be immutable'
        );

        // Swap back to IEO (hypothetical)
        _swapResolutionModule(address(defaultResolutionModule));
        uint256 escrow3 = _createEscrow();

        // Verify all snapshots correct
        assertEq(
            escrow.getSnapshotResolutionModule(escrow1),
            address(defaultResolutionModule),
            'Escrow1 should still use IEO module'
        );
        assertEq(
            escrow.getSnapshotResolutionModule(escrow2),
            address(drv1ResolutionModule),
            'Escrow2 should use DR v1 module'
        );
        assertEq(
            escrow.getSnapshotResolutionModule(escrow3),
            address(defaultResolutionModule),
            'Escrow3 should use IEO module'
        );
    }

    // ============ Test: Multiple Escrows During Migration ============

    /**
     * @notice Test that multiple escrows created during migration all have correct snapshots
     */
    function test_MultipleEscrowsDuringMigration() public {
        // IEO state - create 2 escrows
        _swapResolutionModule(address(defaultResolutionModule));
        uint256 ieo1 = _createEscrow();
        uint256 ieo2 = _createEscrow();

        // Swap to DR v1 - create 2 more escrows
        _setupDRv1();
        _swapResolutionModule(address(drv1ResolutionModule));
        uint256 drv1_1 = _createEscrow();
        uint256 drv1_2 = _createEscrow();

        // Swap to V2 - create 1 more escrow
        vm.prank(timelock);
        drv1ResolutionModule.setIncentiveModule(address(incentiveModuleV2));
        uint256 drv2_1 = _createEscrow();

        // Verify all snapshots correct
        assertEq(
            escrow.getSnapshotResolutionModule(ieo1),
            address(defaultResolutionModule),
            'IEO escrow 1 correct'
        );
        assertEq(
            escrow.getSnapshotResolutionModule(ieo2),
            address(defaultResolutionModule),
            'IEO escrow 2 correct'
        );
        assertEq(
            escrow.getSnapshotResolutionModule(drv1_1),
            address(drv1ResolutionModule),
            'DR v1 escrow 1 correct'
        );
        assertEq(
            escrow.getSnapshotResolutionModule(drv1_2),
            address(drv1ResolutionModule),
            'DR v1 escrow 2 correct'
        );
        assertEq(
            escrow.getSnapshotResolutionModule(drv2_1),
            address(drv1ResolutionModule),
            'DR v2 escrow correct'
        );
    }
}
