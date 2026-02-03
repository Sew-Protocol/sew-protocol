// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
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
    function depositForYield(uint256, address, uint256, address) external pure override returns (bool success, uint256 yieldTokenBalance) {
        return (false, 0); // SILENT FAILURE
    }
    function withdrawWithYield(uint256, address, uint256, address) external pure override returns (bool success, uint256 actualAmount, uint256 yieldAmount) {
        return (true, 0, 0); // SUCCESSFULLY WITHDREW 0
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
        return interfaceId == type(IYieldGenerationModule).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract YieldDepositFailureBugTest is Test {
    EscrowVault public escrow;
    ERC20Mock public token;
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
        token = new ERC20Mock("Token", "TKN", owner, 0);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleManagementContract(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        silentModule = new SilentFailureModule();

        escrow = new EscrowVault(0, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        
        yieldOps.registerEscrowContract(address(escrow));
        disputeOps.registerEscrowContract(address(escrow));
        moduleManagement.registerEscrowContract(address(escrow));
        createOps.registerEscrowContract(address(escrow));
        settlementOps.registerEscrowContract(address(escrow));
        bondCollector.registerEscrowContract(address(escrow));

        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), owner);
        escrow.setCreateOps(address(createOps));
        escrow.setSettlementOps(address(settlementOps));
        escrow.setBondCollector(address(bondCollector));
        escrow.setResolutionModule(address(resolutionModule));

        // Configure silent module as default yield gen module
        moduleManagement.queueModule(address(escrow), BaseEscrow.ModuleType.YIELD_GEN, address(silentModule));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(escrow), BaseEscrow.ModuleType.YIELD_GEN);

        token.mint(user1, 1000 ether);
    }

    function test_YieldDepositFailure_LossOfFunds() public {
        // 1. Create escrow with yield enabled
        // This SHOULD now fail because the module returns success=false or doesn't pull tokens
        vm.startPrank(user1);
        token.approve(address(escrow), 100 ether);
        vm.expectRevert(); // AccountingDeficit
        escrow.createEscrow(address(token), user2, 100 ether, EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        }));
        vm.stopPrank();

        // 2. Verify state - Escrow was NOT created
        assertEq(escrow.getEscrowCount(), 0);
        assertEq(token.balanceOf(user1), 1000 ether, "User should still have their tokens");
    }
}
