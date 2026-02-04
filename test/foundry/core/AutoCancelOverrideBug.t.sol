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
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/CreateOps.sol";

contract MockAppealModule is DefaultResolutionModule {
    uint256 public deadline;
    bool public finalRound;

    constructor(address owner, address resolver) DefaultResolutionModule(owner, resolver) {}

    function setDeadline(uint256 _deadline, bool _finalRound) public {
        deadline = _deadline;
        finalRound = _finalRound;
    }

    function getAppealDeadlineAndRound(
        uint256,
        address
    ) external view override returns (uint256 appealDeadline, uint8 currentRound, bool isFinalRound) {
        return (deadline, 1, finalRound);
    }
}

contract AutoCancelOverrideBugTest is Test {
    EscrowVault public escrow;
    ERC20Mock public token;
    MockAppealModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;

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
        resolutionModule = new MockAppealModule(owner, resolver);

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

        token.mint(user1, 1000 ether);
    }

    function test_AutoCancelOverridesPendingSettlement() public {
        // 1. Create escrow
        vm.startPrank(user1);
        token.approve(address(escrow), 100 ether);
        uint256 wid = escrow.createEscrow(address(token), user2, 100 ether, EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        }));
        vm.stopPrank();

        // 2. Raise dispute
        vm.prank(user1);
        escrow.raiseDispute(wid);

        // 3. Resolver decides RELEASE (to user2)
        // Set deadline in the future
        resolutionModule.setDeadline(block.timestamp + 1 days, false);
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(wid, bytes32(0));

        // Verify pending settlement exists
        (bool exists, bool isRelease, uint256 deadline, bytes32 hash) = escrow.pendingSettlements(wid);
        assertTrue(exists);
        assertTrue(isRelease);

        // 4. Wait for maxDisputeDuration (default 90 days in EscrowVault)
        vm.warp(block.timestamp + 91 days);

        // 5. Call autoCancelDisputedEscrow
        // This SHOULD now fail because we have a pending settlement
        vm.expectRevert();
        escrow.autoCancelDisputedEscrow(wid);

        // 6. Verify state - Escrow remains DISPUTED (decision is respected)
        (,,,,,,, EscrowState state,,) = escrow.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.DISPUTED), "Escrow should still be disputed (fix working)");
        
        // Finalize settlement
        vm.warp(deadline + 1);
        escrow.executePendingSettlement(wid);

        // Verify state - Now RELEASED
        (,,,,,,, state,,) = escrow.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.RELEASED), "Escrow should be released after settlement execution");
    }
}
