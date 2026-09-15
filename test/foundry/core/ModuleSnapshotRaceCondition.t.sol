// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";

contract SimpleReleaseStrategy is IReleaseStrategy {
    
    function canRelease(uint256, address, address, bytes calldata) external pure override returns (bool, uint8) {
        return (true, 0);
    }
    function strategyName() external pure override returns (string memory) { return "Simple"; }
    function moduleName() external pure override returns (string memory) { return "Simple"; }
    function moduleVersion() external pure override returns (string memory) { return "1.0.0"; }
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReleaseStrategy).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract ModuleSnapshotRaceConditionTest is Test {
    EscrowVault public vault;
    ModuleSnapshotRegistry public mm;
    SimpleReleaseStrategy public strategyA;
    SimpleReleaseStrategy public strategyB;
    ERC20Mock public token;

    address public owner = address(this);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);

    function setUp() public {
        mm = new ModuleSnapshotRegistry(owner);
        strategyA = new SimpleReleaseStrategy();
        strategyB = new SimpleReleaseStrategy();
        token = new ERC20Mock("Token", "TKN", owner, 1000e18);

        vault = new EscrowVault(0,address(0xFEE),address(new YieldOps(owner)),address(mm));
        
        mm.registerEscrowContract(address(vault));
        
        // Setup initial default strategy.
        mm.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(strategyA));
        vm.warp(block.timestamp + 7 days + 1);
        mm.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        // Configure ops
        CreateOps co = new CreateOps(owner);
        co.grantRole(co.ROLE_TIMELOCK(), owner);
        co.registerEscrowContract(address(vault));
        vault.setCreateOps(address(co));
        
        DefaultResolutionModule rm = new DefaultResolutionModule(owner, address(0xDEAD));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.setResolutionModule(address(rm));
    }

    function test_snapshot_preserves_module_after_swap() public {
        // 1. Create escrow while strategy A is active.
        vm.startPrank(buyer);
        token.mint(buyer, 100e18);
        token.approve(address(vault), 100e18);
        uint256 wid = vault.createEscrow(address(token), seller, 100e18, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        // 2. Verify the escrow snapshots strategy A.
        // struct ModuleSnapshot: resolution, release, cancellation, yieldGen, yieldDist, incentive, yieldFee, appealFee, escrowFee, autoRelease, autoCancel, maxDispute, appealWindow
        (, address snapRelease, , , , , , , , , , , ) = vault.moduleSnapshots(wid);
        assertEq(snapRelease, address(strategyA));

        // 3. Swap the default to strategy B.
        mm.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(strategyB));
        vm.warp(block.timestamp + 7 days + 1);
        mm.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        // 4. Verify new default is strategy B.
        assertEq(mm.getModule(address(vault), BaseEscrow.ModuleType.RELEASE), address(strategyB));

        // 5. Verify the original escrow remains bound to strategy A.
        (, snapRelease, , , , , , , , , , , ) = vault.moduleSnapshots(wid);
        assertEq(snapRelease, address(strategyA));
    }
}
