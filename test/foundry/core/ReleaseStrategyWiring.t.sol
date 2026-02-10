// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import { EscrowVault } from "../../../contracts/core/EscrowVault.sol";
import { ModuleSnapshotRegistry } from "../../../contracts/core/ModuleSnapshotRegistry.sol";
import { YieldOps } from "../../../contracts/ops/YieldOps.sol";
import { DisputeOps } from "../../../contracts/ops/DisputeOps.sol";
import { CreateOps } from "../../../contracts/ops/CreateOps.sol";
import { SettlementOps } from "../../../contracts/ops/SettlementOps.sol";
import { BondCollector } from "../../../contracts/core/BondCollector.sol";
import { DefaultResolutionModule } from "../../../contracts/core/modules/DefaultResolutionModule.sol";
import { ERC20Mock } from "../../../contracts/mocks/ERC20Mock.sol";

import { IReleaseStrategy } from "../../../contracts/interfaces/IReleaseStrategy.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import { EscrowSettings } from "../../../contracts/types/EscrowTypes.sol";
import { YieldPreset } from "../../../contracts/types/YieldPresets.sol";
import { BaseEscrow } from "../../../contracts/core/BaseEscrow.sol";

contract ReleaseStrategyMockS1 is ERC165, IReleaseStrategy {
    function canRelease(
        uint256,
        address,
        address,
        bytes calldata
    ) external pure override returns (bool allowed, uint8 reasonCode) {
        return (true, 0);  // REASON_ALLOWED
    }

    function executeRelease(
        uint256,
        address,
        bytes calldata
    ) external pure override returns (bool success) {
        revert('ReleaseStrategyMockS1: executeRelease not implemented in v1');
    }

    function strategyName() external pure override returns (string memory name) {
        return "S1";
    }

    function moduleName() external pure override returns (string memory name) {
        return "S1";
    }

    function moduleVersion() external pure override returns (string memory version) {
        return "1.0.0";
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IReleaseStrategy).interfaceId || super.supportsInterface(interfaceId);
    }
}

contract ReleaseStrategyMockS2 is ERC165, IReleaseStrategy {
    function canRelease(
        uint256,
        address,
        address,
        bytes calldata
    ) external pure override returns (bool allowed, uint8 reasonCode) {
        return (true, 0);  // REASON_ALLOWED
    }

    function executeRelease(
        uint256,
        address,
        bytes calldata
    ) external pure override returns (bool success) {
        revert('ReleaseStrategyMockS2: executeRelease not implemented in v1');
    }

    function strategyName() external pure override returns (string memory name) {
        return "S2";
    }

    function moduleName() external pure override returns (string memory name) {
        return "S2";
    }

    function moduleVersion() external pure override returns (string memory version) {
        return "1.0.0";
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IReleaseStrategy).interfaceId || super.supportsInterface(interfaceId);
    }
}

contract EscrowVaultReleaseStrategyHarness is EscrowVault {
    constructor(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) EscrowVault(escrowFeeBps, feeAddress, yieldOpsAddress, disputeOpsAddress, moduleManagementAddress) {}

    function snapReleaseStrategy(uint256 workflowId) external view returns (address) {
        return moduleSnapshots[workflowId].releaseStrategy;
    }

    function resolvedReleaseStrategy(uint256 workflowId) external view returns (address) {
        address snap = moduleSnapshots[workflowId].releaseStrategy;
        if (snap != address(0)) {
            return snap;
        }
        // If no snapshot, fall back to current default
        return address(_getReleaseStrategy(workflowId));
    }
}

contract ReleaseStrategyWiringTest is Test {
    ModuleSnapshotRegistry internal mm;
    EscrowVaultReleaseStrategyHarness internal vault;
    YieldOps internal yieldOps;
    DisputeOps internal disputeOps;
    CreateOps internal createOps;
    SettlementOps internal settlementOps;
    BondCollector internal bondCollector;
    DefaultResolutionModule internal resolutionModule;

    address internal constant FEE = address(0xFEE);
    address internal buyer = address(0xB0B);
    address internal seller = address(0xA11CE);

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));

        vault = new EscrowVaultReleaseStrategyHarness(0, FEE, address(yieldOps), address(disputeOps), address(mm));

        // Register escrow contract so it can queue/activate modules (msg.sender must be the escrow itself).
        mm.registerEscrowContract(address(vault));

        // Wire required ops for createEscrow
        createOps = new CreateOps(address(this));
        createOps.grantRole(createOps.ROLE_TIMELOCK(), address(this));
        createOps.registerEscrowContract(address(vault));

        settlementOps = new SettlementOps(address(this));
        settlementOps.registerEscrowContract(address(vault));

        bondCollector = new BondCollector(address(this));
        bondCollector.registerEscrowContract(address(vault));

        // EscrowVault setters are timelock-gated; deployer has ROLE_TIMELOCK in constructor.
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        // Ensure createEscrow can choose a dispute resolver (resolution module must be configured).
        resolutionModule = new DefaultResolutionModule(address(this), address(0x1234));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setResolutionModule(address(resolutionModule));
    }

    function _createEscrow() internal returns (uint256 workflowId) {
        ERC20Mock token = new ERC20Mock("TKN", "TKN", address(this), 1e24);
        token.transfer(buyer, 1e20);
        vm.startPrank(buyer);
        token.approve(address(vault), 1e20);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        workflowId = vault.createEscrow(address(token), seller, 1e20, settings);
        vm.stopPrank();
    }

    function _setDefaultReleaseStrategy(address newStrategy) internal {
        vm.prank(address(this));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, newStrategy);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(this));
        mm.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);
    }

    function test_releaseStrategy_snapshot_persists_across_default_updates() public {
        ReleaseStrategyMockS1 s1 = new ReleaseStrategyMockS1();
        ReleaseStrategyMockS2 s2 = new ReleaseStrategyMockS2();

        _setDefaultReleaseStrategy(address(s1));

        uint256 wid0 = _createEscrow();
        assertEq(vault.snapReleaseStrategy(wid0), address(s1), "snapshot should capture default release strategy");
        assertEq(vault.resolvedReleaseStrategy(wid0), address(s1), "resolved strategy should use snapshot");

        _setDefaultReleaseStrategy(address(s2));

        // Existing escrow keeps the snapshotted strategy.
        assertEq(vault.snapReleaseStrategy(wid0), address(s1), "snapshot should not change");
        assertEq(vault.resolvedReleaseStrategy(wid0), address(s1), "resolved strategy should remain snapshotted");

        // New escrows snapshot the updated default.
        uint256 wid1 = _createEscrow();
        assertEq(vault.snapReleaseStrategy(wid1), address(s2), "new escrow should snapshot updated default");
        assertEq(vault.resolvedReleaseStrategy(wid1), address(s2), "resolved strategy should use new snapshot");
    }

    function test_releaseStrategy_snapshot_zero_means_follow_future_default() public {
        // No default set at creation time -> snapshot stays 0.
        uint256 wid0 = _createEscrow();
        assertEq(vault.snapReleaseStrategy(wid0), address(0), "snapshot should be zero when default unset");
        assertEq(vault.resolvedReleaseStrategy(wid0), address(0), "resolved strategy is zero when default unset");

        // Later setting a default affects escrows whose snapshot was zero.
        ReleaseStrategyMockS1 s1 = new ReleaseStrategyMockS1();
        _setDefaultReleaseStrategy(address(s1));

        assertEq(vault.snapReleaseStrategy(wid0), address(0), "snapshot remains zero");
        assertEq(vault.resolvedReleaseStrategy(wid0), address(s1), "resolved strategy follows current default if snapshot zero");
    }

    function test_queueModule_release_requires_timelock() public {
        ReleaseStrategyMockS1 s1 = new ReleaseStrategyMockS1();
        bytes32 role = mm.ROLE_TIMELOCK();

        // Not the timelock -> fails.
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", address(0xBEEF), role));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(s1));
    }
}

