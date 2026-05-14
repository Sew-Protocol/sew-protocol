// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/BaseEscrow.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";

contract RepeatAttackerMitigationsTest is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;

    address public owner;
    address public timelock;
    address public guardian;
    address public feeAddress = address(0xFEE);
    address public resolver = address(0x1234);
    address public attacker = address(0xA11A);
    address public seller = address(0x1002);

    uint256 constant AMOUNT = 1000e18;
    uint256 constant DUST = 1e15; // 0.001 tokens

    function setUp() public {
        owner = address(this);
        timelock = address(0x1);
        guardian = address(0x2);

        token = new ERC20Mock("Test", "TEST", owner, 1_000_000e18);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);

        vault = new EscrowVault(0, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        moduleManagement.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_GUARDIAN(), guardian);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);

        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));

        resolutionModule.grantRole(resolutionModule.ROLE_TIMELOCK(), owner);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────

    function _createEscrow(address buyer, uint256 amount) internal returns (uint256 wid) {
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        wid = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fix 1: Minimum dispute escrow value
    // ═══════════════════════════════════════════════════════════════════════════

    function test_minDisputeValue_DisabledByDefault() public {
        assertEq(vault.minDisputeEscrowValue(), 0);
        // Dust dispute succeeds with no minimum set
        uint256 wid = _createEscrow(attacker, DUST);
        vm.prank(attacker);
        vault.raiseDispute(wid); // should not revert
    }

    function test_minDisputeValue_SetByAdmin() public {
        vault.setMinDisputeEscrowValue(100e18);
        assertEq(vault.minDisputeEscrowValue(), 100e18);
    }

    function test_minDisputeValue_SetEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit MinDisputeEscrowValueUpdated(50e18);
        vault.setMinDisputeEscrowValue(50e18);
    }

    function test_minDisputeValue_RevertsOnDustDispute() public {
        vault.setMinDisputeEscrowValue(100e18);
        uint256 wid = _createEscrow(attacker, DUST);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(DisputeAmountBelowMinimum.selector, wid, DUST, 100e18)
        );
        vault.raiseDispute(wid);
    }

    function test_minDisputeValue_AllowsEscrowAtMinimum() public {
        vault.setMinDisputeEscrowValue(100e18);
        uint256 wid = _createEscrow(attacker, 100e18);
        vm.prank(attacker);
        vault.raiseDispute(wid); // exactly at minimum — should succeed
    }

    function test_minDisputeValue_AllowsEscrowAboveMinimum() public {
        vault.setMinDisputeEscrowValue(100e18);
        uint256 wid = _createEscrow(attacker, AMOUNT);
        vm.prank(attacker);
        vault.raiseDispute(wid);
    }

    function test_minDisputeValue_OnlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setMinDisputeEscrowValue(100e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fix 2: Per-sender dispute rate limit
    // ═══════════════════════════════════════════════════════════════════════════

    function test_disputeRateLimit_DisabledByDefault() public {
        assertEq(vault.maxDisputesPerSenderPerDay(), 0);
        // Multiple disputes from same sender succeed with no limit
        for (uint256 i = 0; i < 5; i++) {
            uint256 wid = _createEscrow(attacker, AMOUNT);
            vm.prank(attacker);
            vault.raiseDispute(wid);
        }
    }

    function test_disputeRateLimit_SetByAdmin() public {
        vault.setMaxDisputesPerSenderPerDay(3);
        assertEq(vault.maxDisputesPerSenderPerDay(), 3);
    }

    function test_disputeRateLimit_SetEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit MaxDisputesPerSenderPerDayUpdated(5);
        vault.setMaxDisputesPerSenderPerDay(5);
    }

    function test_disputeRateLimit_AllowsUpToLimit() public {
        vault.setMaxDisputesPerSenderPerDay(3);
        for (uint256 i = 0; i < 3; i++) {
            uint256 wid = _createEscrow(attacker, AMOUNT);
            vm.prank(attacker);
            vault.raiseDispute(wid);
        }
        assertEq(vault.senderDisputeCount(attacker), 3);
    }

    function test_disputeRateLimit_RevertsOnExceed() public {
        vault.setMaxDisputesPerSenderPerDay(2);
        for (uint256 i = 0; i < 2; i++) {
            uint256 wid = _createEscrow(attacker, AMOUNT);
            vm.prank(attacker);
            vault.raiseDispute(wid);
        }
        uint256 wid3 = _createEscrow(attacker, AMOUNT);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(DisputeRateLimitExceeded.selector, attacker, uint32(3), uint32(2))
        );
        vault.raiseDispute(wid3);
    }

    function test_disputeRateLimit_ResetsAfterWindow() public {
        vault.setMaxDisputesPerSenderPerDay(2);
        // Fill the window
        for (uint256 i = 0; i < 2; i++) {
            uint256 wid = _createEscrow(attacker, AMOUNT);
            vm.prank(attacker);
            vault.raiseDispute(wid);
        }
        // Advance past 1 day window
        vm.warp(block.timestamp + 1 days + 1);
        // New window: should succeed again
        uint256 widNew = _createEscrow(attacker, AMOUNT);
        vm.prank(attacker);
        vault.raiseDispute(widNew);
        assertEq(vault.senderDisputeCount(attacker), 1);
    }

    function test_disputeRateLimit_IndependentPerAddress() public {
        vault.setMaxDisputesPerSenderPerDay(1);
        address other = address(0xB0B);
        uint256 wid1 = _createEscrow(attacker, AMOUNT);
        vm.prank(attacker);
        vault.raiseDispute(wid1);

        // Different sender should be unaffected
        uint256 wid2 = _createEscrow(other, AMOUNT);
        vm.prank(other);
        vault.raiseDispute(wid2); // should not revert
    }

    function test_disputeRateLimit_OnlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setMaxDisputesPerSenderPerDay(5);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fix 3: Escalation cooldown (setter only — escalation requires full DRM setup)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_escalationCooldown_DisabledByDefault() public {
        assertEq(vault.escalationCooldown(), 0);
    }

    function test_escalationCooldown_SetByAdmin() public {
        vault.setEscalationCooldown(1 days);
        assertEq(vault.escalationCooldown(), 1 days);
    }

    function test_escalationCooldown_SetEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit EscalationCooldownUpdated(12 hours);
        vault.setEscalationCooldown(12 hours);
    }

    function test_escalationCooldown_OnlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setEscalationCooldown(1 days);
    }

    // ─── Event declarations (mirror BaseEscrow) ──────────────────────────────
    event MinDisputeEscrowValueUpdated(uint256 newValue);
    event MaxDisputesPerSenderPerDayUpdated(uint32 newMax);
    event EscalationCooldownUpdated(uint64 newCooldown);
}
