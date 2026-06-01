// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/interfaces/IReleaseStrategy.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Exposes production module getters (not a reimplementation of snapshot logic).
contract EscrowVaultModuleGetterHarness is EscrowVault {
    constructor(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) EscrowVault(escrowFeeBps, feeAddress, yieldOpsAddress, disputeOpsAddress, moduleManagementAddress) {}

    function effectiveReleaseStrategy(uint256 workflowId) external view returns (address) {
        return address(_getReleaseStrategy(workflowId));
    }

    function effectiveYieldDistributionModule(uint256 workflowId) external view returns (address) {
        return address(_getYieldDistributionModule(workflowId));
    }

    function effectiveCancellationStrategy(uint256 workflowId) external view returns (address) {
        return _getCancellationStrategy(workflowId);
    }

    function effectiveResolutionModule(uint256 workflowId) external view returns (address) {
        return address(_getResolutionModule(workflowId));
    }

    function effectiveYieldGenerationModule(uint256 workflowId) external view returns (address) {
        return address(_getYieldGenerationModule(workflowId));
    }

    function getModuleSnapshot(uint256 workflowId) external view returns (ModuleSnapshot memory) {
        return moduleSnapshots[workflowId];
    }
}

/// @title ForwardOnlyModuleSnapshotTest
/// @notice Ensures EscrowVault runtime module resolution honors creation-time snapshots
///         after governance swaps defaults (forward-only upgrades).
contract ForwardOnlyModuleSnapshotTest is Test {
    EscrowVaultModuleGetterHarness internal vault;
    ModuleSnapshotRegistry internal mm;
    ERC20Mock internal token;

    DefaultReleaseStrategy internal allowRelease;
    AlwaysRejectReleaseStrategy internal denyRelease;
    DefaultYieldDistributionModule internal yieldDistA;
    DefaultYieldDistributionModule internal yieldDistB;
    DefaultResolutionModule internal resolution;

    address internal buyer = address(0xB0B);
    address internal seller = address(0xA11CE);
    address internal constant FEE = address(0xFEE);

    function setUp() public {
        YieldOps yieldOps = new YieldOps(address(this));
        DisputeOps disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));

        allowRelease = new DefaultReleaseStrategy();
        denyRelease = new AlwaysRejectReleaseStrategy();
        yieldDistA = new DefaultYieldDistributionModule();
        yieldDistB = new DefaultYieldDistributionModule();
        resolution = new DefaultResolutionModule(address(this), address(0x1234));

        vault = new EscrowVaultModuleGetterHarness(
            0, FEE, address(yieldOps), address(disputeOps), address(mm)
        );

        mm.registerEscrowContract(address(vault));

        CreateOps createOps = new CreateOps(address(this));
        createOps.registerEscrowContract(address(vault));
        SettlementOps settlementOps = new SettlementOps(address(this));
        settlementOps.registerEscrowContract(address(vault));
        BondCollector bondCollector = new BondCollector(address(this));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolution));

        token = new ERC20Mock("TKN", "TKN", address(this), 1e24);
        token.transfer(buyer, 1e22);
    }

    function _activateModule(BaseEscrow.ModuleType moduleType, address module) internal {
        mm.queueModule(address(vault), moduleType, module);
        vm.warp(block.timestamp + 7 days + 1);
        mm.activateModule(address(vault), moduleType);
    }

    function _createEscrow() internal returns (uint256 workflowId) {
        vm.startPrank(buyer);
        token.approve(address(vault), 1e20);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        workflowId = vault.createEscrow(address(token), seller, 1e20, settings);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Release strategy: behavioral forward-only
    // -------------------------------------------------------------------------

    function test_release_uses_snapshotted_strategy_after_default_swap() public {
        _activateModule(BaseEscrow.ModuleType.RELEASE, address(allowRelease));
        uint256 wid = _createEscrow();

        assertEq(vault.getModuleSnapshot(wid).releaseStrategy, address(allowRelease));
        assertEq(vault.effectiveReleaseStrategy(wid), address(allowRelease));

        _activateModule(BaseEscrow.ModuleType.RELEASE, address(denyRelease));

        assertEq(mm.getModule(address(vault), BaseEscrow.ModuleType.RELEASE), address(denyRelease));
        assertEq(vault.getModuleSnapshot(wid).releaseStrategy, address(allowRelease));
        assertEq(vault.effectiveReleaseStrategy(wid), address(allowRelease));

        vm.prank(buyer);
        vault.release(wid);

        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.RELEASED), "snapshotted allow strategy should release");
    }

    function test_release_new_escrow_uses_new_default_after_swap() public {
        _activateModule(BaseEscrow.ModuleType.RELEASE, address(allowRelease));
        uint256 widOld = _createEscrow();

        _activateModule(BaseEscrow.ModuleType.RELEASE, address(denyRelease));
        uint256 widNew = _createEscrow();

        assertEq(vault.effectiveReleaseStrategy(widOld), address(allowRelease));
        assertEq(vault.effectiveReleaseStrategy(widNew), address(denyRelease));

        vm.prank(buyer);
        vm.expectRevert();
        vault.release(widNew);
    }

    // -------------------------------------------------------------------------
    // Yield distribution: getter must match non-zero snapshot
    // -------------------------------------------------------------------------

    function test_yield_distribution_getter_matches_snapshot_after_default_swap() public {
        _activateModule(BaseEscrow.ModuleType.YIELD_DIST, address(yieldDistA));
        uint256 wid = _createEscrow();

        assertEq(vault.getModuleSnapshot(wid).yieldDistributionModule, address(yieldDistA));
        assertEq(vault.effectiveYieldDistributionModule(wid), address(yieldDistA));

        _activateModule(BaseEscrow.ModuleType.YIELD_DIST, address(yieldDistB));

        assertEq(vault.getModuleSnapshot(wid).yieldDistributionModule, address(yieldDistA));
        assertEq(vault.effectiveYieldDistributionModule(wid), address(yieldDistA));
    }

    // -------------------------------------------------------------------------
    // All snapshotted module axes: runtime getter == storage when snapshot non-zero
    // -------------------------------------------------------------------------

    function test_all_module_getters_match_snapshot_when_set() public {
        _activateModule(BaseEscrow.ModuleType.RELEASE, address(allowRelease));
        _activateModule(BaseEscrow.ModuleType.YIELD_DIST, address(yieldDistA));

        uint256 wid = _createEscrow();
        ModuleSnapshot memory snap = vault.getModuleSnapshot(wid);

        assertTrue(snap.releaseStrategy != address(0));
        assertEq(vault.effectiveReleaseStrategy(wid), snap.releaseStrategy);
        assertEq(vault.effectiveYieldDistributionModule(wid), snap.yieldDistributionModule);
        assertEq(vault.effectiveCancellationStrategy(wid), snap.cancellationStrategy);
        assertEq(vault.effectiveResolutionModule(wid), snap.resolutionModule);
        assertEq(vault.effectiveYieldGenerationModule(wid), snap.yieldGenerationModule);
    }
}

/// @notice Release strategy that always rejects (distinct behavior from DefaultReleaseStrategy).
contract AlwaysRejectReleaseStrategy is ERC165, IReleaseStrategy {
    function canRelease(
        uint256,
        address,
        address,
        bytes calldata
    ) external pure override returns (bool allowed, uint8 reasonCode) {
        return (false, 1);
    }

    function executeRelease(
        uint256,
        address,
        bytes calldata
    ) external pure override returns (bool success) {
        success;
        revert("AlwaysRejectReleaseStrategy: executeRelease not implemented");
    }

    function strategyName() external pure override returns (string memory) {
        return "AlwaysReject";
    }

    function moduleName() external pure override returns (string memory) {
        return "AlwaysReject";
    }

    function moduleVersion() external pure override returns (string memory) {
        return "1.0.0";
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IReleaseStrategy).interfaceId || super.supportsInterface(interfaceId);
    }
}
