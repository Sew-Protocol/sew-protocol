// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/BaseEscrow.sol";
import "../../../contracts/core/EscrowViewContract.sol";
import "../../../contracts/CreateOps.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";
import "../../../contracts/SettlementOps.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";

contract UXIntegrationTests is Test {
    EscrowVault public vault;
    EscrowViewContract public escrowView;
    CreateOps public createOps;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    ModuleSnapshotRegistry public moduleManagement;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;

    address public owner = address(0x1);
    address public timelock = address(0x2);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public resolverAddr = address(0xDEAD);
    address public feeAddress = address(0xFEE);

    event TimedActionTriggered(
        uint256 indexed workflowId,
        uint8 actionType,
        ExecutionSource source,
        address indexed executor
    );

    function setUp() public {
        vm.startPrank(owner);
        createOps = new CreateOps(owner);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        settlementOps = new SettlementOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        
        vault = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        
        resolutionModule = new DefaultResolutionModule(owner, resolverAddr);
        moduleManagement.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        
        token = new ERC20Mock("Test", "TEST", buyer, 10000e18);
        escrowView = new EscrowViewContract(address(vault));
        vm.stopPrank();
        
        vm.prank(buyer);
        token.approve(address(vault), type(uint256).max);
    }

    function test_UrgencyLevels_Transitions() public {
        uint256 offset = 50 hours;
        uint256 autoReleaseTime = block.timestamp + offset;
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;

        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, 1000e18, settings);

        // LOW urgency (> 48h)
        EscrowTimeline memory timeline = escrowView.getEscrowTimeline(wid);
        assertEq(uint8(timeline.urgency), uint8(UrgencyLevel.LOW));
        assertFalse(timeline.userCanExecute);

        // Jump to CRITICAL urgency (< 1h)
        vm.warp(autoReleaseTime - 30 minutes);
        timeline = escrowView.getEscrowTimeline(wid);
        assertEq(uint8(timeline.urgency), uint8(UrgencyLevel.CRITICAL));

        // READY_TO_EXECUTE (Time met)
        vm.warp(autoReleaseTime + 1);
        timeline = escrowView.getEscrowTimeline(wid);
        assertEq(uint8(timeline.status), uint8(ActionableStatus.TIME_CONDITION_MET));
        assertEq(uint8(timeline.urgency), uint8(UrgencyLevel.NONE));
        assertTrue(timeline.userCanExecute);
    }

    function test_TimedActionTriggered_Event() public {
        uint256 autoReleaseTime = block.timestamp + 1 days;
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;

        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, 1000e18, settings);

        vm.warp(autoReleaseTime + 1);

        // Expect event from KEEPER (random address)
        vm.expectEmit(true, false, false, true);
        emit TimedActionTriggered(wid, 1, ExecutionSource.KEEPER, address(0x999));
        vm.prank(address(0x999));
        vault.automateTimedActions(wid);
    }

    function test_WorkflowsByRole_Filtering() public {
        vm.prank(buyer);
        vault.createEscrow(address(token), seller, 1000e18, SettingsValidationLibrary.getDefaultSettings());
        vm.prank(buyer);
        vault.createEscrow(address(token), seller, 1000e18, SettingsValidationLibrary.getDefaultSettings());

        uint256[] memory buyerEscrows = escrowView.getWorkflowsByRole(buyer, UserRole.BUYER, 0, 10);
        assertEq(buyerEscrows.length, 2);
        assertEq(buyerEscrows[0], 0);
        assertEq(buyerEscrows[1], 1);

        uint256[] memory sellerEscrows = escrowView.getWorkflowsByRole(seller, UserRole.SELLER, 0, 10);
        assertEq(sellerEscrows.length, 2);

        uint256[] memory otherEscrows = escrowView.getWorkflowsByRole(address(0x999), UserRole.BUYER, 0, 10);
        assertEq(otherEscrows.length, 0);
    }

    function test_canAutomate_View() public {
        uint256 autoReleaseTime = block.timestamp + 1 days;
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;

        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, 1000e18, settings);

        // Before expiry
        (bool ok, uint8 actionType, bool isRelease, , ) = escrowView.canAutomate(wid);
        assertFalse(ok);
        assertEq(actionType, 0);

        // After expiry
        vm.warp(autoReleaseTime + 1);
        (ok, actionType, isRelease, , ) = escrowView.canAutomate(wid);
        assertTrue(ok);
        assertEq(actionType, 1);
        assertTrue(isRelease);
    }

    function test_PremiumUX_Helpers() public {
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.customResolver = address(resolutionModule);
        
        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, 1000e18, settings);

        // 1. Yield Metrics (Principal check - 1000e18 minus 1% fee = 990e18)
        YieldMetrics memory metrics = escrowView.getYieldMetrics(wid);
        assertEq(metrics.principal, 990e18);
        assertEq(metrics.yieldToken, address(token));

        // 2. Consensus Status (Agree to cancel)
        vm.prank(buyer);
        vault.senderCancel(wid);
        CollaborationStatus memory status = escrowView.getConsensusStatus(wid);
        assertTrue(status.senderAgreed);
        assertFalse(status.recipientAgreed);
        assertFalse(status.canFinalize);

        // 3. Resolver Context
        ResolverContext memory ctx = escrowView.getResolverContext(wid);
        assertEq(ctx.resolver, address(resolutionModule));
        assertTrue(ctx.isContract);
        assertEq(ctx.label, "DefaultSingleResolver");
    }
}
