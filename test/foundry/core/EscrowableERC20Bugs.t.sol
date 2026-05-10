// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowableERC20.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/admin/EscrowGovernanceTimelock.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/interfaces/IYieldGenerationModule.sol";

contract SilentFailureModule is IYieldGenerationModule {
    function depositForYield(uint256, address, uint256, address) external pure override returns (bool success, uint256 yieldTokenBalance) {
        return (false, 0); // SILENT FAILURE
    }
    function withdrawWithYield(uint256, address, uint256, address) external pure override returns (bool success, uint256 actualAmount, uint256 yieldAmount) {
        return (true, 0, 0);
    }
    function getPosition(uint256, address, address) external pure override returns (YieldPosition memory) {
        return YieldPosition(false, 0, 0, 0);
    }
    function calculateYield(uint256, address, address) external pure override returns (uint256) { return 0; }
    function isTokenSupported(address) external pure override returns (bool) { return true; }
    function getApprovalTarget(address) external pure override returns (address) { return address(0); }
    function moduleName() external pure override returns (string memory) { return "SilentFailure"; }
    function moduleVersion() external pure override returns (string memory) { return "1.0.0"; }
    function getAavePoolAddress() external pure override returns (address) { return address(0); }
    function getATokenAddress(address) external pure override returns (address) { return address(0); }
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IYieldGenerationModule).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

contract EscrowableERC20BugsTest is Test {
    EscrowableERC20 public escrowToken;
    DefaultReleaseStrategy public releaseStrategy;
    ERC20Mock public otherToken;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;
    SilentFailureModule public silentModule;

    address public owner;
    address public feeAddress = address(0xFEE);
    address public resolver = address(0x1234);
    address public user1 = address(0x1001);
    address public user2 = address(0x1002);

    function setUp() public {
        owner = address(this);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        adminContract = new EscrowGovernanceTimelock(owner);
        releaseStrategy = new DefaultReleaseStrategy();
        silentModule = new SilentFailureModule();

        escrowToken = new EscrowableERC20(
            "EscrowToken", "ESC", 0, feeAddress, 
            address(yieldOps), address(disputeOps), address(moduleManagement)
        );
        
        otherToken = new ERC20Mock("Other", "OTH", owner, 1000 ether);

        yieldOps.registerEscrowContract(address(escrowToken));
        disputeOps.registerEscrowContract(address(escrowToken));
        moduleManagement.registerEscrowContract(address(escrowToken));
        createOps.registerEscrowContract(address(escrowToken));
        settlementOps.registerEscrowContract(address(escrowToken));
        bondCollector.registerEscrowContract(address(escrowToken));
        adminContract.registerEscrowContract(address(escrowToken));

        escrowToken.grantRole(escrowToken.ROLE_TIMELOCK(), owner);
        escrowToken.setCreateOps(address(createOps));
        escrowToken.setSettlementOps(address(settlementOps));
        escrowToken.setBondCollector(address(bondCollector));

        // Configure silent module via Registry
        vm.startPrank(owner);
        moduleManagement.queueModule(address(escrowToken), BaseEscrow.ModuleType.YIELD_GEN, address(silentModule));
        moduleManagement.queueModule(address(escrowToken), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(escrowToken), BaseEscrow.ModuleType.RELEASE);
        moduleManagement.activateModule(address(escrowToken), BaseEscrow.ModuleType.YIELD_GEN);
        vm.stopPrank();

        escrowToken.transfer(user1, 1000 ether);
    }

    function test_EscrowableERC20_DepositBug() public {
        // 1. Create escrow with yield enabled
        // This SHOULD now fail because the module returns success=false
        vm.startPrank(user1);
        escrowToken.approve(address(escrowToken), 100 ether);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;

        vm.expectRevert(); // AccountingDeficit
        escrowToken.createEscrow(address(escrowToken), user2, 100 ether, settings);
        vm.stopPrank();
    }

    function test_EscrowableERC20_ReleaseFunction() public {
        // Test releaseEscrowTransfer
        vm.startPrank(user1);
        escrowToken.approve(address(escrowToken), 100 ether);
        uint256 wid = escrowToken.createEscrow(address(escrowToken), user2, 100 ether, SettingsValidationLibrary.getDefaultSettings());
        
        escrowToken.release(wid);
        vm.stopPrank();

        assertEq(escrowToken.balanceOf(user2), 100 ether, "User should get tokens via releaseEscrowTransfer");
    }
}
