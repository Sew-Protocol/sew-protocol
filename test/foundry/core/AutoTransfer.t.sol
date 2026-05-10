// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/core/modules/DefaultResolutionModule.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/ops/YieldOps.sol';
import 'contracts/ops/DisputeOps.sol';
import 'contracts/ops/SettlementOps.sol';
import 'contracts/ops/CreateOps.sol';
import 'contracts/core/BondCollector.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/admin/EscrowGovernanceTimelock.sol';
import 'contracts/libraries/SettingsValidationLibrary.sol';

/**
 * @title PullOnlySettlementTest
 * @notice Settlement must create claimable entitlement and never push-transfer user funds.
 */
contract AutoTransferTest is Test {
    EscrowVault vault;
    ERC20Mock token;
    DefaultResolutionModule rm;
    YieldOps yieldOps;
    DisputeOps disputeOps;
    SettlementOps settlementOps;
    CreateOps createOps;
    BondCollector bondCollector;
    ModuleSnapshotRegistry moduleManagement;
    EscrowGovernanceTimelock adminContract;

    address sender = address(0x10);
    address recipient = address(0x20);
    address resolver = address(0x50);
    address feeAddress = address(0x60);

    uint256 constant ESCROW_FEE = 100; // 1%
    uint256 constant AMOUNT = 10 ether;

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        adminContract = new EscrowGovernanceTimelock(address(this));
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(vault));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        token = new ERC20Mock('Test', 'TST', address(this), 1e24);
        rm = new DefaultResolutionModule(address(this), resolver);

        vault.grantRole(vault.ROLE_TIMELOCK(), address(this));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        adminContract.queueResolutionModule(address(vault), address(rm));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(vault));

        token.transfer(sender, 1000 ether);
    }

    function test_release_creates_claimable_not_direct_transfer() public {
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 expected = AMOUNT - fee;

        uint256 balBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        assertEq(token.balanceOf(recipient), balBefore, 'recipient must not be paid during settlement');
        assertEq(vault.claimableBalances(wid, recipient), expected, 'claimable must be created');

        vm.prank(recipient);
        uint256 withdrawn = vault.withdrawEscrow(wid);
        assertEq(withdrawn, expected);
        assertEq(token.balanceOf(recipient) - balBefore, expected, 'delivery occurs only at withdraw');
    }

    function test_cancel_creates_claimable_not_direct_transfer() public {
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 expected = AMOUNT - fee;

        uint256 senderBalBefore = token.balanceOf(sender);

        vm.prank(sender);
        vault.senderCancel(wid);
        vm.prank(recipient);
        vault.recipientCancel(wid);

        assertEq(token.balanceOf(sender), senderBalBefore, 'sender must not be paid during settlement');
        assertEq(vault.claimableBalances(wid, sender), expected, 'refund entitlement must be claimable');
    }
}
