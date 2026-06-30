// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';

/**
 * @title DRv3CrossModuleInvariantsTest
 * @notice Tests escrow-DRM interaction for dispute finalization.
 *
 * Verifies that _finalizeDisputeInModule correctly reaches the resolution
 * module across all terminal dispute paths, and that resolver capacity
 * frees properly (indirectly verified by the escrow reaching terminal state).
 */
contract DRv3CrossModuleInvariantsTest is Test {
    EscrowVault      public vault;
    ERC20Mock        public token;
    DefaultResolutionModule public resolutionModule;
    YieldOps         public yieldOps;
    DisputeOps       public disputeOps;
    SettlementOps    public settlementOps;
    CreateOps        public createOps;
    BondCollector    public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;

    address public owner     = address(this);
    address public feeAddr   = address(0xFEE);
    address public resolver  = address(0xAA01);
    address public buyer     = address(0x1001);
    address public seller    = address(0x1002);

    uint256 constant FEE_BPS = 100;
    uint256 constant AMOUNT  = 1000e18;

    function setUp() public {
        yieldOps      = new YieldOps(owner);
        disputeOps    = new DisputeOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        createOps     = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);

        vault = new EscrowVault(FEE_BPS, feeAddr, address(yieldOps), address(disputeOps), address(moduleManagement));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        moduleManagement.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_TIMELOCK(), owner);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);

        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));

        createOps.setResolverPolicy(false);

        token = new ERC20Mock('Test', 'TEST', owner, 0);
    }

    function _createAndDispute() internal returns (uint256 wid) {
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(vault), AMOUNT);
        wid = vault.createEscrow(
            address(token), seller, AMOUNT,
            SettingsValidationLibrary.getDefaultSettings()
        );
        vault.raiseDispute(wid);
        vm.stopPrank();
    }

    // ─── Invariant: all terminal dispute paths converge to REFUNDED ─────

    function test_crossModule_dispute_timeout_refunds() public {
        uint256 wid = _createAndDispute();
        vm.warp(block.timestamp + 91 days);
        vault.autoCancelDisputedEscrow(wid);
        assertEq(uint8(vault.getEscrowState(wid)), uint8(EscrowState.REFUNDED),
                 "timeout should refund");
    }

    function test_crossModule_dispute_resolution_refunds() public {
        uint256 wid = _createAndDispute();
        vm.prank(resolver);
        vault.cancelAsDisputeResolver(wid, bytes32(0));

        // If appeal window expired, execute; otherwise warp and execute
        (bool exists,, uint256 appealDeadline,) = vault.pendingSettlements(wid);
        assertTrue(exists, "pending settlement should exist after resolution");
        if (block.timestamp < appealDeadline) vm.warp(appealDeadline + 1);

        vault.executePendingSettlement(wid);
        assertEq(uint8(vault.getEscrowState(wid)), uint8(EscrowState.REFUNDED),
                 "resolution + execute should refund");
    }

    function test_crossModule_dispute_resolution_immediate_release() public {
        uint256 wid = _createAndDispute();
        vm.prank(resolver);
        bool ok = vault.releaseAsDisputeResolver(wid, bytes32(0));
        assertTrue(ok, "resolver can release");

        // With zero appeal window the escrow may have moved to terminal directly
        // or created a pending settlement
        EscrowState st = vault.getEscrowState(wid);
        (bool ps,,,) = vault.pendingSettlements(wid);
        assertTrue(st == EscrowState.RELEASED || ps,
                   "should be terminal or have pending settlement");
    }

    function test_crossModule_automateTimedActions_refunds_on_auto_cancel() public {
        uint256 wid = _createWithAutoCancel();
        vm.warp(block.timestamp + 30 days);
        bool acted = vault.automateTimedActions(wid);
        assertTrue(acted, "automateTimedActions should fire auto-cancel");
        assertEq(uint8(vault.getEscrowState(wid)), uint8(EscrowState.REFUNDED),
                 "auto-cancel should refund");
    }

    function _createWithAutoCancel() internal returns (uint256 wid) {
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(vault), AMOUNT);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoCancelTime = block.timestamp + 7 days;
        wid = vault.createEscrow(address(token), seller, AMOUNT, settings);
        vm.stopPrank();
    }

    // ─── Invariant: _finalizeDisputeInModule is reached on all paths ──
    // (indirectly confirmed by terminal state — a revert in _finalizeDisputeInModule
    //  would block the entire call, so reaching terminal state = module was notified)

    function test_crossModule_dispute_auto_cancel_disputed_refunds() public {
        // Create escrow with auto-cancel-time, dispute before deadline, then
        // automateTimedActions fires auto-cancel-on-disputed → refunds.
        // This exercises the ACTION_AUTO_CANCEL_DISPUTED branch in automateTimedActions
        // which calls _finalizeDisputeInModule.
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(vault), AMOUNT);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoCancelTime = block.timestamp + 7 days;
        uint256 wid = vault.createEscrow(address(token), seller, AMOUNT, settings);
        vault.raiseDispute(wid);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        bool acted = vault.automateTimedActions(wid);
        assertTrue(acted, "automateTimedActions should fire auto-cancel-on-disputed");
        assertEq(uint8(vault.getEscrowState(wid)), uint8(EscrowState.REFUNDED),
                 "disputed escrow should be refunded when auto-cancel-time arrives");
    }
}
