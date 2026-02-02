// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowableERC20.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";
import "../../../contracts/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleManagementContract.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/CreateOps.sol";
import "../../../contracts/interfaces/IYieldGenerationModule.sol";

contract SilentFailureModule is IYieldGenerationModule {
    function depositForYield(uint256, address, uint256) external pure override returns (bool success, uint256 yieldTokenBalance) {
        return (false, 0); // SILENT FAILURE
    }
    function withdrawWithYield(uint256, address, uint256, address) external pure override returns (bool success, uint256 actualAmount, uint256 yieldAmount) {
        return (true, 0, 0);
    }
    function calculateYield(uint256, address) external pure override returns (uint256) { return 0; }
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
    ERC20Mock public otherToken;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleManagementContract public moduleManagement;
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
        moduleManagement = new ModuleManagementContract(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);
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

        escrowToken.grantRole(escrowToken.ROLE_ADMIN_CONTRACT(), owner);
        escrowToken.setCreateOps(address(createOps));
        escrowToken.setSettlementOps(address(settlementOps));
        escrowToken.setBondCollector(address(bondCollector));
        escrowToken.setResolutionModule(address(resolutionModule));

        // Configure silent module
        moduleManagement.queueModule(address(escrowToken), BaseEscrow.ModuleType.YIELD_GEN, address(silentModule));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(escrowToken), BaseEscrow.ModuleType.YIELD_GEN);

        escrowToken.transfer(user1, 1000 ether);
    }

    function test_EscrowableERC20_RecoveryBug() public {
        // Send external tokens to the contract
        otherToken.transfer(address(escrowToken), 100 ether);
        assertEq(otherToken.balanceOf(address(escrowToken)), 100 ether);

        // Attempt to recover - SHOULD NOW SUCCEED
        vm.prank(owner);
        escrowToken.recoverERC20(address(otherToken), owner, 100 ether);
        
        assertEq(otherToken.balanceOf(owner), 1000 ether, "Tokens should be recovered");
        assertEq(otherToken.balanceOf(address(escrowToken)), 0);
    }

    function test_EscrowableERC20_DepositBug() public {
        // 1. Create escrow with yield enabled
        // This SHOULD now fail because the module returns success=false or doesn't pull tokens
        vm.startPrank(user1);
        escrowToken.approve(address(escrowToken), 100 ether);
        vm.expectRevert(); // AccountingDeficit or OperationFailure
        escrowToken.createEscrow(address(escrowToken), user2, 100 ether, EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        }));
        vm.stopPrank();
    }

    function test_EscrowableERC20_ReleaseFunction() public {
        // Test newly added releaseEscrowTransfer
        vm.startPrank(user1);
        escrowToken.approve(address(escrowToken), 100 ether);
        uint256 wid = escrowToken.createEscrow(address(escrowToken), user2, 100 ether, EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        }));
        
        escrowToken.releaseEscrowTransfer(wid);
        vm.stopPrank();

        assertEq(escrowToken.balanceOf(user2), 100 ether, "User should get tokens via releaseEscrowTransfer");
    }
}
