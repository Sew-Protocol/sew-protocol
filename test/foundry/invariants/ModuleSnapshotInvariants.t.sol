// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../core/ForwardOnlyModuleSnapshot.t.sol";
import "../../../contracts/core/BaseEscrow.sol";
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

/// @title ModuleSnapshotInvariants
/// @notice Fuzzed lifecycle + module default swaps; invariant checks that runtime getters
///         honor per-escrow snapshots (forward-only upgrade guarantee).
contract ModuleSnapshotInvariants is Test {
    EscrowVaultModuleGetterHarness internal vault;
    ModuleSnapshotRegistry internal mm;
    ModuleSnapshotInvariantHandler internal handler;

    DefaultReleaseStrategy internal releaseA;
    DefaultReleaseStrategy internal releaseB;
    DefaultYieldDistributionModule internal yieldDistA;
    DefaultYieldDistributionModule internal yieldDistB;

    function setUp() public {
        YieldOps yieldOps = new YieldOps(address(this));
        DisputeOps disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));

        releaseA = new DefaultReleaseStrategy();
        releaseB = new DefaultReleaseStrategy();
        yieldDistA = new DefaultYieldDistributionModule();
        yieldDistB = new DefaultYieldDistributionModule();

        vault = new EscrowVaultModuleGetterHarness(
            100, address(0xFEE), address(yieldOps), address(disputeOps), address(mm)
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
        vault.setResolutionModule(
            address(new DefaultResolutionModule(address(this), address(0x999)))
        );

        ERC20Mock token = new ERC20Mock("TKN", "TKN", address(this), 1e30);
        token.transfer(address(0x1001), 1e28);

        handler = new ModuleSnapshotInvariantHandler(
            vault,
            mm,
            token,
            releaseA,
            releaseB,
            yieldDistA,
            yieldDistB
        );
        mm.grantRole(mm.ROLE_TIMELOCK(), address(handler));

        targetContract(address(handler));

        _activate(BaseEscrow.ModuleType.RELEASE, address(releaseA));
        _activate(BaseEscrow.ModuleType.YIELD_DIST, address(yieldDistA));
    }

    function _activate(BaseEscrow.ModuleType moduleType, address module) internal {
        mm.queueModule(address(vault), moduleType, module);
        (, uint64 eta,) = mm.getPendingModule(address(vault), moduleType);
        vm.warp(uint256(eta) + 1);
        mm.activateModule(address(vault), moduleType);
    }

    /// @dev When a non-zero address is snapshotted, runtime getters must not follow later defaults.
    function invariant_snapshotted_modules_are_effective() public view {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            ModuleSnapshot memory snap = vault.getModuleSnapshot(i);

            if (snap.releaseStrategy != address(0)) {
                assertEq(
                    vault.effectiveReleaseStrategy(i),
                    snap.releaseStrategy,
                    "release getter must use snapshot"
                );
            }

            if (snap.yieldDistributionModule != address(0)) {
                assertEq(
                    vault.effectiveYieldDistributionModule(i),
                    snap.yieldDistributionModule,
                    "yield distribution getter must use snapshot"
                );
            }

            if (snap.cancellationStrategy != address(0)) {
                assertEq(
                    vault.effectiveCancellationStrategy(i),
                    snap.cancellationStrategy,
                    "cancellation getter must use snapshot"
                );
            }

            if (snap.resolutionModule != address(0)) {
                assertEq(
                    vault.effectiveResolutionModule(i),
                    snap.resolutionModule,
                    "resolution getter must use snapshot"
                );
            }

            if (snap.yieldGenerationModule != address(0)) {
                assertEq(
                    vault.effectiveYieldGenerationModule(i),
                    snap.yieldGenerationModule,
                    "yield generation getter must use snapshot"
                );
            }
        }
    }
}

/// @notice Creates escrows and occasionally swaps vault default modules.
contract ModuleSnapshotInvariantHandler is Test {
    EscrowVaultModuleGetterHarness public vault;
    ModuleSnapshotRegistry public mm;
    ERC20Mock public token;

    DefaultReleaseStrategy public releaseA;
    DefaultReleaseStrategy public releaseB;
    DefaultYieldDistributionModule public yieldDistA;
    DefaultYieldDistributionModule public yieldDistB;

    address public buyer = address(0x1001);
    address public seller = address(0x1002);

    constructor(
        EscrowVaultModuleGetterHarness _vault,
        ModuleSnapshotRegistry _mm,
        ERC20Mock _token,
        DefaultReleaseStrategy _releaseA,
        DefaultReleaseStrategy _releaseB,
        DefaultYieldDistributionModule _yieldDistA,
        DefaultYieldDistributionModule _yieldDistB
    ) {
        vault = _vault;
        mm = _mm;
        token = _token;
        releaseA = _releaseA;
        releaseB = _releaseB;
        yieldDistA = _yieldDistA;
        yieldDistB = _yieldDistB;
    }

    function createEscrow(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e15, 1e20);
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.OFF;
        vault.createEscrow(address(token), seller, amount, settings);
        vm.stopPrank();
    }

    function swapReleaseDefault(uint256 seed) external {
        address next = seed % 2 == 0 ? address(releaseA) : address(releaseB);
        mm.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, next);
        (, uint64 eta,) = mm.getPendingModule(address(vault), BaseEscrow.ModuleType.RELEASE);
        vm.warp(uint256(eta) + 1);
        mm.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);
    }

    function swapYieldDistDefault(uint256 seed) external {
        address next = seed % 2 == 0 ? address(yieldDistA) : address(yieldDistB);
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST, next);
        (, uint64 eta,) = mm.getPendingModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);
        vm.warp(uint256(eta) + 1);
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);
    }
}
