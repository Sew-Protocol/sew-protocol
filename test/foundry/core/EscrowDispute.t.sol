// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/BaseEscrow.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/EscrowViewContract.sol";
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

contract EscrowDisputeTest is Test {
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
    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public unauthorized = address(0x9999);

    function setUp() public {
        owner = address(this);
        timelock = address(0x1);
        guardian = address(0x2);
        
        token = new ERC20Mock("Test", "TEST", owner, 10000e18);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);

        vault = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        
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

        // Allow this test contract to change the default resolver in DefaultResolutionModule
        resolutionModule.grantRole(resolutionModule.ROLE_TIMELOCK(), owner);
    }

    function test_raiseDispute_NonParticipant() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert(); // NotParticipant
        vault.raiseDispute(wid);
    }

    function test_escalateDispute_NotAllowed() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        
        vault.raiseDispute(wid);
        vm.stopPrank();

        // DefaultResolutionModule does not allow escalation
        vm.prank(buyer);
        vm.expectRevert(); // EscalationNotAllowed
        vault.escalateDispute(wid);
    }

    // S26 Governance Sandwich: after a dispute is raised, the per-escrow assigned resolver
    // (et.disputeResolver) is the sole authority. A governance call to
    // DefaultResolutionModule.setResolver() CANNOT inject a replacement resolver that acts
    // on the in-flight dispute. The originally assigned resolver retains exclusive authority.
    function test_Dispute_GlobalResolverChange_BlocksNewResolverOnActiveDispute() public {
        uint256 amount = 1000e18;
        address newResolver = address(0xDEAD);

        // Buyer creates escrow with default settings (no customResolver)
        token.mint(buyer, amount);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(
            address(token),
            seller,
            amount,
            SettingsValidationLibrary.getDefaultSettings()
        );
        vm.stopPrank();

        // Snapshot the per-escrow resolver chosen at creation time
        ( , , , address snapResolver, , , , , , ) = vault.escrowTransfers(wid);
        assertEq(snapResolver, resolver, "initial per-escrow resolver should be DefaultResolutionModule.resolver");

        // Move escrow into DISPUTED state
        vm.prank(buyer);
        vault.raiseDispute(wid);

        // Governance attempts to inject a new resolver into the live module.
        resolutionModule.setResolver(newResolver);
        assertEq(resolutionModule.resolver(), newResolver, "global resolver updated");

        // S26 guard: the governance-injected resolver MUST NOT be able to act on this
        // already-active dispute. et.disputeResolver was frozen at dispute-raise time.
        vm.prank(newResolver);
        vm.expectRevert(); // NotAuthorizedResolver
        vault.releaseAsDisputeResolver(wid, bytes32("attacker-hash"));

        // The original assigned resolver remains the sole authority and can still resolve.
        vm.prank(resolver);
        vault.releaseAsDisputeResolver(wid, bytes32("legitimate-hash"));

        ( , , , , , , , EscrowState stAfter, , ) = vault.escrowTransfers(wid);
        assertEq(uint256(stAfter), uint256(EscrowState.DISPUTED), "escrow should remain DISPUTED with pending settlement");

        (bool exists, bool isRelease, uint256 appealDeadline, ) = vault.pendingSettlements(wid);
        assertTrue(exists, "pending settlement should exist");
        assertTrue(isRelease, "pending settlement should be a release");
        assertGt(appealDeadline, block.timestamp, "appeal deadline should be in the future");
    }

    function test_Dispute_CustomResolver_OverriddenByGlobalResolverChange() public {
        uint256 amount = 1000e18;
        address newResolver = address(0xBEEF);

        // Deploy a custom resolver contract (must have code)
        TestCustomResolver customResolver = new TestCustomResolver();

        // Buyer creates escrow with explicit customResolver
        token.mint(buyer, amount);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.customResolver = address(customResolver);

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), seller, amount, settings);
        vm.stopPrank();

        // Confirm per-escrow resolver is the custom one
        ( , , , address resolverOnTransfer, , , , , , ) = vault.escrowTransfers(wid);
        assertEq(resolverOnTransfer, address(customResolver), "disputeResolver should be customResolver");

        // Move escrow into DISPUTED state
        vm.prank(buyer);
        vault.raiseDispute(wid);

        // Before global resolver change, newResolver is NOT authorized
        vm.startPrank(newResolver);
        vm.expectRevert(); // NotAuthorizedResolver
        vault.releaseAsDisputeResolver(wid, bytes32("before-change"));
        vm.stopPrank();

        // Governance updates the global default resolver in DefaultResolutionModule
        resolutionModule.setResolver(newResolver);
        assertEq(resolutionModule.resolver(), newResolver, "global resolver should be updated");

        // After global resolver change, newResolver is still NOT authorized for this escrow
        vm.startPrank(newResolver);
        vm.expectRevert(); // NotAuthorizedResolver
        vault.releaseAsDisputeResolver(wid, bytes32("after-change"));
        vm.stopPrank();

        // The per-escrow customResolver remains the only authorized resolver
        vm.prank(address(customResolver));
        vault.releaseAsDisputeResolver(wid, bytes32("custom-resolver"));

        // As with the global resolver test, DefaultResolutionModule does not expose
        // appeal metadata, so SettlementOps creates a pending settlement and the
        // escrow stays DISPUTED until executePendingSettlement is called.
        ( , , , , , , , EscrowState stAfter, , ) = vault.escrowTransfers(wid);
        assertEq(uint256(stAfter), uint256(EscrowState.DISPUTED), "escrow should remain DISPUTED with pending settlement after customResolver decision");

        (bool exists, bool isRelease, uint256 appealDeadline, ) = vault.pendingSettlements(wid);
        assertTrue(exists, "pending settlement should exist for customResolver decision");
        assertTrue(isRelease, "pending settlement from customResolver should be a release");
        assertGt(appealDeadline, block.timestamp, "appeal deadline should be in the future");
    }

    function test_escalateDispute_v1_reverts_AppealsNotEnabledInV1() public {
        // V1 launch: Appeals are disabled. Even if someone tries to escalate, they hit the
        // resolution module check first (DefaultResolutionModule.computeEscalation returns false),
        // which reverts with EscalationNotAllowed.
        // 
        // The AppealsNotEnabledInV1() check in escalateDispute() provides an additional safety
        // layer that will be enforced in Phase 2 when the resolution module supports escalation
        // but the incentive module is null.
        
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        
        // Enter disputed state
        vault.raiseDispute(wid);
        vm.stopPrank();
        
        // Attempt to escalate - reverts because DefaultResolutionModule does not support escalation
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSignature("EscalationNotAllowed()"));
        vault.escalateDispute(wid);
    }
}

contract TestCustomResolver {
    // Intentionally empty; only existence (code size > 0) matters for SettingsValidationLibrary
}
