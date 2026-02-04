// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";
import "../../../contracts/CreateOps.sol";
import "../../../contracts/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/mocks/ERC20Mock.sol";

contract RevertingERC20 is ERC20Mock {
    bool public shouldRevert = false;

    constructor() ERC20Mock("Reverting", "REV", msg.sender, 0) {}

    function setShouldRevert(bool _shouldRevert) public {
        shouldRevert = _shouldRevert;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (shouldRevert) {
            revert("Transfer failed");
        }
        return super.transfer(to, amount);
    }
}

contract VaultAccountingBugTest is Test {
    EscrowVault public escrow;
    RevertingERC20 public token;
    DefaultResolutionModule public resolutionModule;
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
        token = new RevertingERC20();
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        createOps = new CreateOps(owner);
        settlementOps = new SettlementOps(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);

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

    function test_AccountingBreakdown_ClaimableBug() public {
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

        // Check initial accounting
        (uint256 principal, uint256 fees, uint256 bal, uint256 yield) = escrow.getAccountingBreakdown(address(token));
        assertEq(principal, 100 ether);
        assertEq(fees, 0);
        assertEq(bal, 100 ether);
        assertEq(yield, 0);

        // 2. Release escrow but make transfer fail -> moves to claimable
        token.setShouldRevert(true);
        vm.prank(user1);
        escrow.releaseEscrowTransfer(wid);

        // Verify state
        assertEq(escrow.claimableBalances(wid, user2), 100 ether);
        assertEq(escrow.totalHeldInEscrowPerToken(address(token)), 0);
        assertEq(token.balanceOf(address(escrow)), 100 ether);

        // 3. Check accounting breakdown - SHOULD BE principal=0, fees=0, bal=100, yield=0
        (principal, fees, bal, yield) = escrow.getAccountingBreakdown(address(token));
        
        assertEq(principal, 0);
        assertEq(yield, 0, "Yield should be zero, claimable funds are correctly tracked now");
    }
}
