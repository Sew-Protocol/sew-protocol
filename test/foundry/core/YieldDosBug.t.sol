// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/interfaces/IYieldModule.sol";

contract OverreportingModule is IYieldModule {
    function initializeYield(
        uint256 /* escrowId */,
        address token,
        uint256 amount,
        YieldPreset /* yieldMode */
    ) external override returns (uint256) {
        // Actually pull tokens so createEscrow succeeds
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function unwindToEscrow(
        uint256 /* escrowId */,
        address token,
        uint256 principalExpected
    ) external override returns (uint256 principalOut, uint256 yieldOut) {
        // Send BACK the original tokens so YieldOps sees "received"
        IERC20(token).transfer(msg.sender, principalExpected);
        // Report 1000 ether EXTRA yield but don't transfer any tokens for it
        return (principalExpected, 1000 ether);
    }

    function emergencyUnwind(
        uint256 /* escrowId */,
        address token,
        uint256 principalExpected
    ) external override returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 toReturn = principalExpected > balance ? balance : principalExpected;
        if (toReturn > 0) {
            IERC20(token).transfer(msg.sender, toReturn);
        }
        return toReturn;
    }

    function canHandle(
        address /* token */,
        YieldPreset /* mode */,
        uint256 /* amount */
    ) external pure override returns (bool, bytes32) {
        return (true, bytes32(0));
    }

    function getModuleInfo()
        external pure override returns (string memory, string memory, bytes32) {
        return ("Overreporter", "1.0.0", keccak256("overreporter"));
    }
}

contract YieldDosBugTest is Test {
    EscrowVault public escrow;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    OverreportingModule public overreporter;

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
        moduleManagement = new ModuleSnapshotRegistry(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        overreporter = new OverreportingModule();

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

        // Configure overreporter
        moduleManagement.queueModule(address(escrow), BaseEscrow.ModuleType.YIELD_GEN, address(overreporter));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(escrow), BaseEscrow.ModuleType.YIELD_GEN);

        token.mint(user1, 1000 ether);
    }

    function test_YieldOverreport_DosRelease() public {
        // 1. Create escrow with yield
        vm.startPrank(user1);
        token.approve(address(escrow), 100 ether);
        uint256 wid = escrow.createEscrow(address(token), user2, 100 ether, EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        }));
        vm.stopPrank();

        // 2. Try to release escrow
        // This SHOULD FAIL because the Vault tries to push 1000 ether of "yield" to YieldOps,
        // but it doesn't have enough tokens (balance is only 100 ether).
        vm.prank(user1);
        vm.expectRevert(); // safeTransfer to YieldOps fails
        escrow.releaseEscrowTransfer(wid);

        // Verify escrow is still PENDING (blocked)
        (,,,,,,, EscrowState state,,) = escrow.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.PENDING), "Escrow should still be pending due to DoS");
    }
}
