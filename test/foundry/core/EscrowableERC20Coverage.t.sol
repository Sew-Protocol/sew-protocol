// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowableERC20.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";
import "../../../contracts/CreateOps.sol";
import "../../../contracts/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleManagementContract.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";

contract EscrowableERC20CoverageTest is Test {
    EscrowableERC20 public token;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleManagementContract public moduleManagement;

    address public owner;
    address public feeAddress = address(0xFEE);
    address public resolver = address(0x1234);
    address public seller = address(0x1002);

    function setUp() public {
        owner = address(this);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleManagementContract(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);

        token = new EscrowableERC20("Test", "TEST", 100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        
        yieldOps.registerEscrowContract(address(token));
        disputeOps.registerEscrowContract(address(token));
        moduleManagement.registerEscrowContract(address(token));
        createOps.registerEscrowContract(address(token));
        settlementOps.registerEscrowContract(address(token));
        bondCollector.registerEscrowContract(address(token));

        token.grantRole(token.ROLE_ADMIN_CONTRACT(), owner);
        token.setCreateOps(address(createOps));
        token.setSettlementOps(address(settlementOps));
        token.setBondCollector(address(bondCollector));
        token.setResolutionModule(address(resolutionModule));
    }

    function test_createEscrow_Convenience() public {
        uint256 amount = 1000e18;
        token.approve(address(token), amount);
        uint256 wid = token.createEscrow(seller, amount);
        assertEq(wid, 0);
    }

    function test_createEscrow_Timing() public {
        uint256 amount = 1000e18;
        token.approve(address(token), amount);
        uint256 wid = token.createEscrow(seller, amount, block.timestamp + 1 days, 0);
        assertEq(wid, 0);
    }

    function test_withdrawFees_Success() public {
        uint256 amount = 1000e18;
        token.approve(address(token), amount);
        token.createEscrow(seller, amount);

        uint256 feeAmount = (amount * 100) / 10000;
        vm.prank(feeAddress);
        token.withdrawFees();
        
        assertEq(token.balanceOf(feeAddress), feeAmount);
        assertEq(token.totalFees(), 0);
    }

    function test_recoverERC20_Success() public {
        // Send tokens to contract manually
        // We need to bypass the totalHeldInEscrow + totalFees
        // Initial supply is 1M. All held by owner.
        token.transfer(address(token), 100e18);
        
        uint256 balBefore = token.balanceOf(owner);
        token.recoverERC20(address(token), owner, 100e18);
        assertEq(token.balanceOf(owner) - balBefore, 100e18);
    }

    function test_Factory() public {
        EscrowableERC20Factory factory = new EscrowableERC20Factory();
        address newToken = factory.createEscrowableERC20(
            "New", "NEW", 100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement)
        );
        assertTrue(newToken != address(0));
        assertEq(EscrowableERC20(newToken).name(), "New");
    }
}