// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../contracts/core/EscrowableERC20.sol";
import "../../../packages/sew-core/contracts/modules/DefaultReleaseStrategy.sol";
import "../../../packages/sew-core/contracts/modules/DefaultResolutionModule.sol";
import "../../../packages/sew-core/contracts/types/EscrowTypes.sol";
import "../../../packages/sew-core/contracts/core/BondCollector.sol";
import "../../../packages/sew-core/contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/admin/EscrowGovernanceTimelock.sol";
import "../../../packages/sew-core/contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../packages/sew-core/contracts/core/EscrowCreationPolicy.sol";
import "../../../contracts/interfaces/IYieldGenerationModule.sol";
import "../../../packages/sew-core/contracts/interfaces/IYieldModule.sol";

contract AllowanceObservingYieldModule is IYieldModule {
    uint256 public observedAllowance;

    function initializeYield(uint256, address token, uint256 amount, YieldPreset) external override returns (uint256) {
        observedAllowance = IERC20(token).allowance(msg.sender, address(this));
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        return amount;
    }
    function unwindToEscrow(uint256, address token, uint256 principalExpected) external override returns (uint256, uint256) {
        IERC20(token).transfer(msg.sender, principalExpected);
        return (principalExpected, 0);
    }
    function emergencyUnwind(uint256, address token, uint256 principalExpected) external override returns (uint256) {
        IERC20(token).transfer(msg.sender, principalExpected);
        return principalExpected;
    }
    function previewPosition(uint256, address) external pure override returns (uint256, uint256, bool) { return (0, 0, false); }
    function canHandle(address, YieldPreset, uint256) external pure override returns (bool, bytes32) { return (true, bytes32(0)); }
    function getModuleInfo() external pure override returns (string memory, string memory, bytes32) { return ("AllowanceObserver", "1", bytes32(0)); }
}

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
    EscrowCreationPolicy public creationPolicy;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;
    SilentFailureModule public silentModule;
    AllowanceObservingYieldModule public allowanceModule;

    address public owner;
    address public feeAddress = address(0xFEE);
    address public resolver = address(0x1234);
    address public user1 = address(0x1001);
    address public user2 = address(0x1002);

    function setUp() public {
        owner = address(this);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        creationPolicy = new EscrowCreationPolicy(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        adminContract = new EscrowGovernanceTimelock(owner);
        releaseStrategy = new DefaultReleaseStrategy();
        silentModule = new SilentFailureModule();
        allowanceModule = new AllowanceObservingYieldModule();

        escrowToken = new EscrowableERC20("EscrowToken","ESC",0,feeAddress,address(moduleManagement));
        
        otherToken = new ERC20Mock("Other", "OTH", owner, 1000 ether);


        escrowToken.grantRole(escrowToken.ROLE_TIMELOCK(), owner);
        escrowToken.setCreationPolicy(address(creationPolicy));
        escrowToken.setBondCollector(address(bondCollector));

        // Configure silent module via Registry
        vm.startPrank(owner);
        moduleManagement.registerEscrowContract(address(escrowToken));
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
        settings.yieldPreset = YieldPreset.ENABLED;

        vm.expectRevert(); // AccountingDeficit
        escrowToken.createEscrow(address(escrowToken), user2, 100 ether, settings);
        vm.stopPrank();
    }

    function test_EscrowableERC20_YieldApprovalIsExactAndCleared() public {
        moduleManagement.queueModule(address(escrowToken), BaseEscrow.ModuleType.YIELD_GEN, address(allowanceModule));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(escrowToken), BaseEscrow.ModuleType.YIELD_GEN);

        vm.startPrank(user1);
        escrowToken.approve(address(escrowToken), 100 ether);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.ENABLED;
        escrowToken.createEscrow(address(escrowToken), user2, 100 ether, settings);
        vm.stopPrank();

        assertEq(allowanceModule.observedAllowance(), 100 ether);
        assertEq(escrowToken.allowance(address(escrowToken), address(allowanceModule)), 0);
    }

    function test_EscrowableERC20_ReleaseFunction() public {
        // Test releaseEscrowTransfer
        vm.startPrank(user1);
        escrowToken.approve(address(escrowToken), 100 ether);
        uint256 wid = escrowToken.createEscrow(address(escrowToken), user2, 100 ether, SettingsValidationLibrary.getDefaultSettings());
        
        escrowToken.release(wid);
        vm.stopPrank();

        // Pull-only settlement: recipient is credited claimable, not paid during release.
        assertEq(escrowToken.balanceOf(user2), 0, "User should not be paid during settlement");
        assertEq(escrowToken.claimableBalances(wid, user2), 100 ether, "Recipient should receive claimable entitlement");
    }
}
