// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/BaseEscrow.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/modules/DefaultYieldModule.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";
import "../../../contracts/CreateOps.sol";
import "../../../contracts/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";

contract PerEscrowSettingsHarness is EscrowVault {
    constructor(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) EscrowVault(escrowFeeBps, feeAddress, yieldOpsAddress, disputeOpsAddress, moduleManagementAddress) {}

    function getReleaseStrategyAddr(uint256 workflowId) external view returns (address) {
        return address(_getReleaseStrategy(workflowId));
    }

    function getResolutionModuleAddr(uint256 workflowId) external view returns (address) {
        return address(_getResolutionModule(workflowId));
    }

    function getModuleSnapshot(uint256 workflowId) external view returns (ModuleSnapshot memory) {
        return moduleSnapshots[workflowId];
    }
}

contract PerEscrowSettingsTest is Test {
    PerEscrowSettingsHarness public vault;
    ModuleSnapshotRegistry public moduleManagement;
    ERC20Mock public token;
    
    DefaultReleaseStrategy public releaseV1;
    DefaultReleaseStrategy public releaseV2;
    DefaultResolutionModule public resolutionV1;
    DefaultResolutionModule public resolutionV2;

    address public owner;
    address public buyer;
    address public seller;
    address public feeAddress;
    address public resolver;

    function setUp() public {
        owner = address(this);
        console.log("ROLE_TIMELOCK:", vm.toString(keccak256("ROLE_TIMELOCK")));
        buyer = address(0xB);
        seller = address(0xC);
        feeAddress = address(0xFEE);
        resolver = address(0xD);

        token = new ERC20Mock("Test", "TEST", buyer, 1000e18);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        
        releaseV1 = new DefaultReleaseStrategy();
        releaseV2 = new DefaultReleaseStrategy();
        resolutionV1 = new DefaultResolutionModule(owner, resolver);
        resolutionV2 = new DefaultResolutionModule(owner, address(0xE));

        vault = new PerEscrowSettingsHarness(
            100, // 1%
            feeAddress,
            address(new YieldOps(owner)),
            address(new DisputeOps(owner)),
            address(moduleManagement)
        );
        vault.grantRole(vault.ROLE_TIMELOCK(), owner);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);

        moduleManagement.registerEscrowContract(address(vault));

        // Setup mandatory ops for createEscrow
        CreateOps createOps = new CreateOps(owner);
        createOps.registerEscrowContract(address(vault));
        vault.setCreateOps(address(createOps));

        SettlementOps settlementOps = new SettlementOps(owner);
        settlementOps.registerEscrowContract(address(vault));
        vault.setSettlementOps(address(settlementOps));

        BondCollector bondCollector = new BondCollector(owner);
        bondCollector.registerEscrowContract(address(vault));
        vault.setBondCollector(address(bondCollector));

        // Initial global modules
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseV1));
        vm.warp(block.timestamp + 7 days + 1);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);
        
        vault.setResolutionModule(address(resolutionV1));
        
        vm.prank(buyer);
        token.approve(address(vault), type(uint256).max);
    }

    function test_PerEscrow_AutoRelease() public {
        uint256 amount = 100e18;
        uint256 autoReleaseTime = block.timestamp + 10 days;
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;
        
        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, amount, settings);
        
        // Warp to just before
        vm.warp(autoReleaseTime - 1);
        assertFalse(vault.automateTimedActions(wid));
        
        // Warp to exactly
        vm.warp(autoReleaseTime);
        assertTrue(vault.automateTimedActions(wid));
        
        ( , , , , , , , EscrowState state, , ) = vault.escrowTransfers(wid);
        assertEq(uint256(state), uint256(EscrowState.RELEASED));
    }

    function test_PerEscrow_AutoCancel() public {
        uint256 amount = 100e18;
        uint256 autoCancelTime = block.timestamp + 5 days;
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoCancelTime = autoCancelTime;
        
        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, amount, settings);
        
        vm.warp(autoCancelTime - 1);
        assertFalse(vault.automateTimedActions(wid));
        
        vm.warp(autoCancelTime);
        assertTrue(vault.automateTimedActions(wid));
        
        ( , , , , , , , EscrowState state, , ) = vault.escrowTransfers(wid);
        assertEq(uint256(state), uint256(EscrowState.REFUNDED));
    }

    function test_PerEscrow_ModuleSnapshotting() public {
        // Escrow 1 created with V1 modules
        vm.prank(buyer);
        uint256 wid1 = vault.createEscrow(address(token), seller, 100e18, SettingsValidationLibrary.getDefaultSettings());
        
        // Change Global Default Release Strategy
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseV2));
        vm.warp(block.timestamp + 7 days + 1);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);
        
        // Change Global Default Resolution Module
        vault.setResolutionModule(address(resolutionV2));
        
        // Escrow 2 created with V2 modules
        vm.prank(buyer);
        uint256 wid2 = vault.createEscrow(address(token), seller, 100e18, SettingsValidationLibrary.getDefaultSettings());
        
        // Verify Escrow 1 still points to V1
        assertEq(vault.getReleaseStrategyAddr(wid1), address(releaseV1));
        assertEq(vault.getResolutionModuleAddr(wid1), address(resolutionV1));
        
        // Verify Escrow 2 points to V2
        assertEq(vault.getReleaseStrategyAddr(wid2), address(releaseV2));
        assertEq(vault.getResolutionModuleAddr(wid2), address(resolutionV2));
    }

    function test_PerEscrow_CustomResolver() public {
        address customResolver = address(resolutionV2);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.customResolver = customResolver;
        
        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, 100e18, settings);
        
        ( , , , address resolverRet, , , , , , ) = vault.escrowTransfers(wid);
        assertEq(resolverRet, customResolver);
    }

    function test_PerEscrow_AllSettings_Applied_And_AccountingStable() public {
        uint256 amount = 100e18;

        // Baseline accounting before creating escrow
        (uint256 principalBefore, uint256 feesBefore, uint256 balanceBefore, ) =
            vault.getAccountingBreakdown(address(token));

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.customResolver = address(resolutionV2); // non-zero contract address
        settings.yieldPreset = YieldPreset.TO_SENDER;
        settings.autoReleaseTime = block.timestamp + 10 days;
        // autoCancelTime must remain 0 when autoReleaseTime is set

        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, amount, settings);

        // Verify settings snapshot in mapping
        (address customResolverRet, YieldPreset yieldPresetRet, uint256 autoReleaseTimeRet, uint256 autoCancelTimeRet) =
            vault.escrowSettings(wid);
        assertEq(customResolverRet, settings.customResolver);
        assertEq(uint256(yieldPresetRet), uint256(settings.yieldPreset));
        assertEq(autoReleaseTimeRet, settings.autoReleaseTime);
        assertEq(autoCancelTimeRet, 0);

        // Verify settings applied onto EscrowTransfer struct
        ( , , , address resolverOnTransfer, , uint64 autoReleaseOnTransfer, uint64 autoCancelOnTransfer, , , ) =
            vault.escrowTransfers(wid);
        assertEq(resolverOnTransfer, settings.customResolver);
        assertEq(autoReleaseOnTransfer, uint64(settings.autoReleaseTime));
        assertEq(autoCancelOnTransfer, 0);

        // Verify accounting delta is independent of per-escrow settings values
        (uint256 principalAfter, uint256 feesAfter, uint256 balanceAfter, ) =
            vault.getAccountingBreakdown(address(token));

        uint256 feeBps = vault.escrowFee();
        uint256 expectedFee = (amount * feeBps) / 10_000;
        uint256 expectedPrincipal = amount - expectedFee;

        assertEq(principalAfter - principalBefore, expectedPrincipal, "principal delta mismatch");
        assertEq(feesAfter - feesBefore, expectedFee, "fee delta mismatch");
        assertEq(balanceAfter - balanceBefore, amount, "balance delta mismatch");
    }

    function test_PerEscrow_DefaultTimeoutsApplied_WhenSettingsZero() public {
        uint256 amount = 100e18;

        // Configure default auto times via admin
        TimeoutConfig memory cfg = TimeoutConfig({
            defaultAutoReleaseDelay: 3 days,
            defaultAutoCancelDelay: 7 days,
            maxDisputeDuration: 90 days,
            appealWindowDuration: 2 days
        });
        vault.setTimeoutConfig(cfg);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        // Both auto times zero -> should use defaults from timeoutConfig

        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, amount, settings);

        // Mapping snapshot keeps raw settings (zeros for times)
        ( , , uint256 autoReleaseTimeSnap, uint256 autoCancelTimeSnap) = vault.escrowSettings(wid);
        assertEq(autoReleaseTimeSnap, 0);
        assertEq(autoCancelTimeSnap, 0);

        // EscrowTransfer struct has effective times from timeoutConfig
        ( , , , , , uint64 autoReleaseOnTransfer, uint64 autoCancelOnTransfer, , , ) =
            vault.escrowTransfers(wid);
        assertEq(autoReleaseOnTransfer, uint64(block.timestamp + cfg.defaultAutoReleaseDelay));
        assertEq(autoCancelOnTransfer, uint64(block.timestamp + cfg.defaultAutoCancelDelay));
    }

    function test_PerEscrow_InvalidCustomResolver_RevertsAndDoesNotCreateEscrow() public {
        uint256 amount = 100e18;
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        // EOA address (no code) should be rejected as customResolver
        settings.customResolver = address(0x1234);

        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, ADDR_INITIAL_RESOLVER, address(0x1234)));
        vault.createEscrow(address(token), seller, amount, settings);
        vm.stopPrank();

        // No escrows should have been created
        assertEq(vault.getEscrowCount(), 0);
    }

    function test_PerEscrow_BothAutoTimesSet_Reverts() public {
        uint256 amount = 100e18;
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = block.timestamp + 5 days;
        settings.autoCancelTime = block.timestamp + 6 days;

        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CannotSetBothAutoTimes.selector, settings.autoReleaseTime, settings.autoCancelTime));
        vault.createEscrow(address(token), seller, amount, settings);
        vm.stopPrank();

        assertEq(vault.getEscrowCount(), 0);
    }

    function test_PerEscrow_AutoReleaseInPast_Reverts() public {
        uint256 amount = 100e18;
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = block.timestamp - 1;

        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(InvalidAutoTime.selector, AUTO_TIME_IN_PAST, settings.autoReleaseTime, block.timestamp));
        vault.createEscrow(address(token), seller, amount, settings);
        vm.stopPrank();

        assertEq(vault.getEscrowCount(), 0);
    }
}