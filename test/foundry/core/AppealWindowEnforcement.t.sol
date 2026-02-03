// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';

/**
 * @title AppealWindowEnforcementTest
 * @notice Comprehensive tests for appeal window enforcement feature
 * @dev Tests that tokens are only transferred after appeal window expires
 */
contract AppealWindowEnforcementTest is Test {
    EscrowVault public escrow;
    DecentralizedResolutionModule public resolutionModule;
    ResolverIncentiveModuleV2 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleManagementContract public moduleManagement;
    EscrowAdminContract public adminContract;

    address public deployer;
    address public timelock;
    address public resolver1;
    address public resolver2;
    address public seniorResolver;
    address public buyer;
    address public seller;
    address public feeAddress;

    uint256 public constant INITIAL_BALANCE = 10000 ether;
    uint256 public constant ESCROW_AMOUNT = 1000 ether;
    uint256 public constant ESCROW_FEE = 100; // 1%

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        resolver1 = makeAddr('resolver1');
        resolver2 = makeAddr('resolver2');
        seniorResolver = makeAddr('seniorResolver');
        buyer = makeAddr('buyer');
        seller = makeAddr('seller');
        feeAddress = makeAddr('feeAddress');

        // Deploy token
        token = new ERC20Mock('Test Token', 'TEST', address(this), 0);
        token.mint(buyer, INITIAL_BALANCE);

        // Deploy payment library
        paymentLib = new PaymentCalculationLibraryV1();

        // Deploy incentive module
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));

        // Deploy resolution module
        resolutionModule = new DecentralizedResolutionModule(deployer);

        // Deploy escrow
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleManagementContract(deployer);
        adminContract = new EscrowAdminContract(deployer);
        escrow = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(escrow));

        // Wire ops contracts (CreateOps / SettlementOps) and register escrow contract callers
        disputeOps.registerEscrowContract(address(escrow));
        settlementOps.registerEscrowContract(address(escrow));
        createOps.registerEscrowContract(address(escrow));
        bondCollector.registerEscrowContract(address(escrow));

        // Also register this test contract as an escrow contract because it calls ops directly
        disputeOps.registerEscrowContract(address(this));
        settlementOps.registerEscrowContract(address(this));
        createOps.registerEscrowContract(address(this));
        bondCollector.registerEscrowContract(address(this));

        // Allow this test contract to wire ops on the vault
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(this));
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(adminContract));
        escrow.setCreateOps(address(createOps));
        escrow.setSettlementOps(address(settlementOps));
        escrow.setBondCollector(address(bondCollector));

        // Setup roles
        bytes32 roleTimelock = resolutionModule.ROLE_TIMELOCK();
        resolutionModule.grantRole(roleTimelock, address(this)); // Grant to self so we can register
        resolutionModule.grantRole(roleTimelock, timelock);

        bytes32 incentiveRoleTimelock = incentiveModule.ROLE_TIMELOCK();
        incentiveModule.grantRole(incentiveRoleTimelock, address(this)); // Grant to self so we can register
        incentiveModule.grantRole(incentiveRoleTimelock, timelock);

        bytes32 escrowRoleTimelock = escrow.ROLE_TIMELOCK();
        escrow.grantRole(escrowRoleTimelock, address(this));

        // Register escrow contract in resolution module
        resolutionModule.registerEscrowContract(address(escrow));
        resolutionModule.registerEscrowContract(address(this)); // Register self because we call setEscrowCategory

        // Register escrow contract in incentive module
        incentiveModule.registerEscrowContract(address(escrow));
        incentiveModule.registerEscrowContract(address(this));
        incentiveModule.registerEscrowContract(address(resolutionModule));

        // Set incentive module in resolution module
        vm.prank(timelock);
        resolutionModule.setIncentiveModule(address(incentiveModule));

        // Set resolution module in escrow
        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(escrow));

        // Appoint resolvers
        vm.prank(timelock);
        resolutionModule.appointSeniorResolver(seniorResolver, 'Senior Resolver', 'Test senior');

        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver1, 'Resolver 1', 'Test resolver');
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver2, 'Resolver 2', 'Test resolver');

        // Activate resolvers
        vm.startPrank(timelock);
        resolutionModule.setResolverActive(seniorResolver, true);
        resolutionModule.setResolverActive(resolver1, true);
        resolutionModule.setResolverActive(resolver2, true);
        resolutionModule.setResolverCapacity(seniorResolver, 0, true);
        resolutionModule.setResolverCapacity(resolver1, 0, true);
        resolutionModule.setResolverCapacity(resolver2, 0, true);
        vm.stopPrank();

        // Set appeal windows (2 days for round 0, 3 days for round 1, 0 for round 2)
        vm.prank(timelock);
        uint256[3] memory resolveDeadlines = [uint256(7 days), 7 days, 7 days];
        uint256[3] memory appealWindows = [uint256(2 days), 3 days, 0];
        resolutionModule.setRoundTimeouts(resolveDeadlines, appealWindows);

        // Enable round 2 escalation for testing final round behavior
        // Setting external resolver enables round 2 escalation
        vm.prank(timelock);
        resolutionModule.setExternalResolver(seniorResolver);
    }

    // ============ Helper Functions ============

    function createEscrow() internal returns (uint256 workflowId) {
        vm.startPrank(buyer);
        token.approve(address(escrow), ESCROW_AMOUNT);
        workflowId = escrow.createEscrow(
            address(token),
            seller,
            ESCROW_AMOUNT,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();
    }

    function raiseDispute(uint256 workflowId) internal {
        // Set category before raising dispute (required for DecentralizedResolutionModule)
        bytes32 category = keccak256('TEST_CATEGORY');
        vm.prank(address(this));
        resolutionModule.setEscrowCategory(workflowId, address(escrow), category);

        // raiseDispute() automatically initializes the dispute via DisputeInitializationLibrary
        vm.prank(buyer);
        escrow.raiseDispute(workflowId);
    }

    // ============ Test: Resolution at Round 0 Stores Pending Settlement ============

    function test_ResolutionAtRound0_StoresPendingSettlement() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        // Get resolver
        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);
        (address resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Resolver resolves (release)
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Check pending settlement exists (public mapping getter returns tuple)
        (bool exists, bool isRelease, uint256 appealDeadline, ) = escrow.pendingSettlements(workflowId);
        bool canExecute = exists && block.timestamp >= appealDeadline;

        assertTrue(exists, 'Pending settlement should exist');
        assertTrue(isRelease, 'Should be pending release');
        assertGt(appealDeadline, block.timestamp, 'Appeal deadline should be in future');
        assertFalse(canExecute, 'Should not be executable yet');

        // Check state is still DISPUTED (not RELEASED)
        // Public array getter returns tuple - extract escrowState
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrow.escrowTransfers(workflowId);
        assertEq(uint8(escrowState), uint8(EscrowState.DISPUTED), 'State should be DISPUTED');

        // Check tokens not transferred yet
        uint256 sellerClaimable = escrow.claimableBalances(workflowId, seller);
        assertEq(sellerClaimable, 0, 'Seller should not have claimable balance yet');
    }

    // ============ Test: Resolution at Final Round Executes Immediately ============

    function test_ResolutionAtFinalRound_ExecutesImmediately() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);

        // Round 0 resolver must first issue a decision before escalation is allowed
        (address round0Resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);
        vm.prank(round0Resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Fund buyer with ETH for escalation bonds
        vm.deal(buyer, 1 ether);

        // Escalate to round 1 (appeal)
        (uint256 bond0, ) = resolutionModule.getRequiredAppealBond(workflowId, address(escrow), 0, escrowData);
        vm.prank(buyer);
        token.approve(address(escrow), bond0);
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        // Round 1 resolver must issue a decision before further escalation is allowed
        (address round1Resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);
        vm.prank(round1Resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Escalate to round 2 (final round) - cost is 0.02 ether (baseCost + stepSize * escalationCount)
        (uint256 bond1, ) = resolutionModule.getRequiredAppealBond(workflowId, address(escrow), 1, escrowData);
        vm.prank(buyer);
        token.approve(address(escrow), bond1);
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        // Get senior resolver for round 2 (after escalation, resolver is updated)
        (address seniorRes, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Senior resolver resolves (release) at final round
        vm.prank(seniorRes);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Check no pending settlement (executed immediately)
        (bool exists, , , ) = escrow.pendingSettlements(workflowId);
        assertFalse(exists, 'No pending settlement for final round');

        // Check state is RELEASED
        // Public array getter returns tuple - extract escrowState
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrow.escrowTransfers(workflowId);
        assertEq(uint8(escrowState), uint8(EscrowState.RELEASED), 'State should be RELEASED');

        // Check tokens transferred via autotransfer
        uint256 sellerClaimable = escrow.claimableBalances(workflowId, seller);
        uint256 sellerBalance = token.balanceOf(seller);
        // Either claimable > 0 (fallback) or balance > 0 (autotransfer succeeded)
        assertTrue(sellerClaimable > 0 || sellerBalance > 0, 'Seller should have either claimable balance or received funds via autotransfer');
    }

    // ============ Test: Appeal Window Expires - Settlement Can Be Executed ============

    function test_AppealWindowExpires_SettlementCanBeExecuted() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        // Get resolver
        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);
        (address resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Resolver resolves (release)
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Get appeal deadline (public mapping getter returns struct tuple)
        (bool exists, , uint256 appealDeadline, ) = escrow.pendingSettlements(workflowId);
        assertTrue(exists);

        // Warp past appeal deadline
        vm.warp(appealDeadline + 1);

        // Execute pending settlement
        escrow.executePendingSettlement(workflowId);

        // Check state is RELEASED
        // Public array getter returns tuple - extract escrowState
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrow.escrowTransfers(workflowId);
        assertEq(uint8(escrowState), uint8(EscrowState.RELEASED), 'State should be RELEASED');

        // Check tokens transferred via autotransfer
        uint256 sellerClaimable = escrow.claimableBalances(workflowId, seller);
        uint256 sellerBalance = token.balanceOf(seller);
        // Either claimable > 0 (fallback) or balance > 0 (autotransfer succeeded)
        assertTrue(sellerClaimable > 0 || sellerBalance > 0, 'Seller should have either claimable balance or received funds via autotransfer');

        // Check pending settlement cleared
        (bool exists_, , , ) = escrow.pendingSettlements(workflowId);
        exists = exists_;
        assertFalse(exists, 'Pending settlement should be cleared');
    }

    // ============ Test: Appeal Window Not Expired - Settlement Cannot Be Executed ============

    function test_AppealWindowNotExpired_SettlementCannotBeExecuted() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        // Get resolver
        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);
        (address resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Resolver resolves (release)
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Get appeal deadline (public mapping getter returns struct tuple)
        (, , uint256 appealDeadline, ) = escrow.pendingSettlements(workflowId);

        // Warp to just before appeal deadline
        vm.warp(appealDeadline - 1);

        // Try to execute pending settlement (should revert)
        vm.expectRevert(abi.encodeWithSignature("AppealWindowNotExpired(uint256,uint256,uint256)", workflowId, appealDeadline, block.timestamp));
        escrow.executePendingSettlement(workflowId);

        // Check state is still DISPUTED
        // Public array getter returns tuple - extract escrowState
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrow.escrowTransfers(workflowId);
        assertEq(
            uint8(escrowState),
            uint8(EscrowState.DISPUTED),
            'State should still be DISPUTED'
        );
    }

    // ============ Test: Escalation During Window Cancels Pending Settlement ============

    function test_EscalationDuringWindow_CancelsPendingSettlement() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        // Get resolver
        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);
        (address resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Resolver resolves (release)
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Check pending settlement exists (public mapping getter returns struct tuple)
        (bool exists, , , ) = escrow.pendingSettlements(workflowId);
        assertTrue(exists, 'Pending settlement should exist');

        // Fund buyer with ETH for escalation bond
        vm.deal(buyer, 1 ether);

        // Escalate during appeal window
        (uint256 bond0, ) = resolutionModule.getRequiredAppealBond(workflowId, address(escrow), 0, escrowData);
        vm.prank(buyer);
        token.approve(address(escrow), bond0);
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        // Check pending settlement cancelled
        (exists, , , ) = escrow.pendingSettlements(workflowId);
        assertFalse(exists, 'Pending settlement should be cancelled');

        // Check state is still DISPUTED (escalation doesn't change state)
        // Public array getter returns tuple - extract escrowState
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrow.escrowTransfers(workflowId);
        assertEq(
            uint8(escrowState),
            uint8(EscrowState.DISPUTED),
            'State should still be DISPUTED'
        );
    }

    // ============ Test: automateTimedActions Executes Pending Settlement ============

    function test_automateTimedActions_ExecutesPendingSettlement() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        // Get resolver
        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);
        (address resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Resolver resolves (release)
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Get appeal deadline (public mapping getter returns struct tuple)
        (, , uint256 appealDeadline, ) = escrow.pendingSettlements(workflowId);

        // Warp past appeal deadline
        vm.warp(appealDeadline + 1);

        // Call automateTimedActions (should execute pending settlement)
        bool success = escrow.automateTimedActions(workflowId);
        assertTrue(success, 'automateTimedActions should succeed');

        // Check state is RELEASED
        // Public array getter returns tuple - extract escrowState
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrow.escrowTransfers(workflowId);
        assertEq(uint8(escrowState), uint8(EscrowState.RELEASED), 'State should be RELEASED');

        // Check tokens transferred via autotransfer
        uint256 sellerClaimable = escrow.claimableBalances(workflowId, seller);
        uint256 sellerBalance = token.balanceOf(seller);
        // Either claimable > 0 (fallback) or balance > 0 (autotransfer succeeded)
        assertTrue(sellerClaimable > 0 || sellerBalance > 0, 'Seller should have either claimable balance or received funds via autotransfer');
    }

    // ============ Test: Multiple Calls to executePendingSettlement Revert ============

    function test_MultipleCallsToExecutePendingSettlement_Revert() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        // Get resolver
        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);
        (address resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Resolver resolves (release)
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Get appeal deadline (public mapping getter returns struct tuple)
        (, , uint256 appealDeadline, ) = escrow.pendingSettlements(workflowId);

        // Warp past appeal deadline
        vm.warp(appealDeadline + 1);

        // First call should succeed
        escrow.executePendingSettlement(workflowId);

        // Second call should revert
        vm.expectRevert(abi.encodeWithSignature("NoPendingSettlement(uint256)", workflowId));
        escrow.executePendingSettlement(workflowId);
    }

    // ============ Test: State Changed - executePendingSettlement Reverts ============

    function test_StateChanged_ExecutePendingSettlementReverts() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        // Get resolver
        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);
        (address resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Resolver resolves (release)
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Get appeal deadline (public mapping getter returns struct tuple)
        (, , uint256 appealDeadline, ) = escrow.pendingSettlements(workflowId);

        // Warp past appeal deadline
        vm.warp(appealDeadline + 1);

        // Execute pending settlement (this deletes the pending settlement and changes state to RELEASED)
        escrow.executePendingSettlement(workflowId);

        // Now pending settlement is deleted and state is RELEASED, so second call should revert
        // The revert happens because pending settlement no longer exists (not because state changed)
        vm.expectRevert(abi.encodeWithSignature("NoPendingSettlement(uint256)", workflowId));
        escrow.executePendingSettlement(workflowId);

        // Verify state is RELEASED (public array getter returns tuple)
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrow.escrowTransfers(workflowId);
        assertEq(uint8(escrowState), uint8(EscrowState.RELEASED), 'State should be RELEASED');
    }

    // ============ Test: Cancel Resolution Also Stores Pending Settlement ============

    function test_CancelResolution_StoresPendingSettlement() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        // Get resolver
        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);
        (address resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Resolver resolves (cancel)
        vm.prank(resolver);
        escrow.cancelAsDisputeResolver(workflowId, bytes32(0));

        // Check pending settlement exists (public mapping getter returns tuple)
        (bool exists, bool isRelease, uint256 appealDeadline, ) = escrow.pendingSettlements(workflowId);
        bool canExecute = exists && block.timestamp >= appealDeadline;

        assertTrue(exists, 'Pending settlement should exist');
        assertFalse(isRelease, 'Should be pending cancel');
        assertGt(appealDeadline, block.timestamp, 'Appeal deadline should be in future');
        assertFalse(canExecute, 'Should not be executable yet');

        // Warp past appeal deadline
        vm.warp(appealDeadline + 1);

        // Execute pending settlement
        escrow.executePendingSettlement(workflowId);

        // Check state is REFUNDED
        // Public array getter returns tuple - extract escrowState
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrow.escrowTransfers(workflowId);
        assertEq(uint8(escrowState), uint8(EscrowState.REFUNDED), 'State should be REFUNDED');

        // Check tokens refunded to buyer via autotransfer
        uint256 buyerClaimable = escrow.claimableBalances(workflowId, buyer);
        uint256 buyerBalance = token.balanceOf(buyer);
        // Either claimable > 0 (fallback) or balance > 0 (autotransfer succeeded)
        assertTrue(buyerClaimable > 0 || buyerBalance > 0, 'Buyer should have either claimable balance or received funds via autotransfer');
    }

    // ============ Test: getPendingSettlement View Function ============

    function test_getPendingSettlement_ViewFunction() public {
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);

        // Get resolver
        bytes memory escrowData = abi.encode(address(token), buyer, seller, ESCROW_AMOUNT);
        (address resolver, ) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);

        // Resolver resolves (release)
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Query pending settlement (public mapping getter returns struct tuple)
        (
            bool exists,
            bool isRelease,
            uint256 appealDeadline,
            bytes32 resolutionHash
        ) = escrow.pendingSettlements(workflowId);
        bool canExecute = block.timestamp >= appealDeadline;

        assertTrue(exists);
        assertTrue(isRelease);
        assertGt(appealDeadline, block.timestamp);
        assertFalse(canExecute);

        // Warp past deadline
        vm.warp(appealDeadline + 1);

        // Query again
        (exists, , appealDeadline, ) = escrow.pendingSettlements(workflowId);
        canExecute = exists && block.timestamp >= appealDeadline;
        assertTrue(canExecute, 'Should be executable now');
    }

    // ============ Test: No Pending Settlement - executePendingSettlement Reverts ============

    function test_NoPendingSettlement_ExecutePendingSettlementReverts() public {
        uint256 workflowId = createEscrow();

        // Try to execute without pending settlement
        vm.expectRevert(abi.encodeWithSignature("NoPendingSettlement(uint256)", workflowId));
        escrow.executePendingSettlement(workflowId);
    }
}
