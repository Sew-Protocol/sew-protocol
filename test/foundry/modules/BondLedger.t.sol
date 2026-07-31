// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/shared/interfaces/IBondLedger.sol';
import '../../../contracts/shared/BondLedger.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

contract BondLedgerTest is Test {
    BondLedger public ledger;
    ERC20Mock public token;

    address public admin = makeAddr('admin');
    address public authorized = makeAddr('authorized');
    address public payer = makeAddr('payer');
    address public funder = makeAddr('funder');
    address public app = makeAddr('app');
    address public recipient = makeAddr('recipient');

    bytes32 constant BOND_ID = keccak256("test-bond");
    uint256 constant PRINCIPAL = 1 ether;

    function setUp() public {
        ledger = new BondLedger(admin);
        vm.prank(admin);
        ledger.addAuthorizedCaller(authorized);

        token = new ERC20Mock("T", "T", address(this), 0);
    }

    function test_postBond_ERC20() public {
        token.mint(funder, PRINCIPAL);
        vm.prank(funder);
        token.approve(address(ledger), PRINCIPAL);

        vm.prank(authorized);
        ledger.postBond(BOND_ID, app, payer, funder, address(token), PRINCIPAL, bytes32(0), bytes32(0));

        IBondLedger.BondPosition memory pos = ledger.getBond(BOND_ID);
        assertEq(uint256(pos.status), uint256(IBondLedger.BondStatus.PENDING));
        assertEq(pos.principal, PRINCIPAL);
        assertEq(pos.payer, payer);
    }

    function test_postBond_ETH() public {
        vm.deal(authorized, PRINCIPAL);
        vm.prank(authorized);
        ledger.postBond{value: PRINCIPAL}(BOND_ID, app, payer, funder, address(0), PRINCIPAL, bytes32(0), bytes32(0));

        IBondLedger.BondPosition memory pos = ledger.getBond(BOND_ID);
        assertEq(pos.principal, PRINCIPAL);
        assertEq(pos.asset, address(0));
    }

    function test_settleBond_singleRefund() public {
        _postBond();

        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
        allocs[0] = IBondLedger.Allocation(payer, PRINCIPAL);

        vm.prank(authorized);
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.REFUND);

        assertEq(ledger.getClaimable(BOND_ID, payer), PRINCIPAL);
    }

    function test_settleBond_multiResolver() public {
        _postBond();
        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");

        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](2);
        allocs[0] = IBondLedger.Allocation(r1, PRINCIPAL / 2);
        allocs[1] = IBondLedger.Allocation(r2, PRINCIPAL - PRINCIPAL / 2);

        vm.prank(authorized);
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.RESOLVER_PAYOUT);

        assertEq(ledger.getClaimable(BOND_ID, r1), PRINCIPAL / 2);
        assertEq(ledger.getClaimable(BOND_ID, r2), PRINCIPAL - PRINCIPAL / 2);
    }

    function test_settleBond_forfeitMovesToReserve() public {
        _postBond();

        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
        allocs[0] = IBondLedger.Allocation(address(0xdead), PRINCIPAL);

        vm.prank(authorized);
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.FORFEIT);

        assertEq(ledger.forfeitedBondReserve(address(token)), PRINCIPAL);
    }

    function test_settleBond_sumMismatchReverts() public {
        _postBond();

        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
        allocs[0] = IBondLedger.Allocation(payer, PRINCIPAL - 1);

        vm.prank(authorized);
        vm.expectRevert();
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.REFUND);
    }

    function test_claim_sendsTokens() public {
        _postBond();
        _settleRefund();

        uint256 before = token.balanceOf(payer);
        ledger.claim(BOND_ID, payer);
        assertEq(token.balanceOf(payer) - before, PRINCIPAL);
    }

    function test_claim_nonRecipientCanTrigger() public {
        _postBond();
        _settleRefund();

        uint256 before = token.balanceOf(payer);
        vm.prank(makeAddr("stranger"));
        ledger.claim(BOND_ID, payer);
        assertEq(token.balanceOf(payer) - before, PRINCIPAL, "stranger can trigger claim for payer");
    }

    function test_doubleClaimReverts() public {
        _postBond();
        _settleRefund();

        ledger.claim(BOND_ID, payer);
        vm.expectRevert();
        ledger.claim(BOND_ID, payer);
    }

    function test_doubleSettleReverts() public {
        _postBond();
        _settleRefund();

        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
        allocs[0] = IBondLedger.Allocation(payer, PRINCIPAL);
        vm.prank(authorized);
        vm.expectRevert();
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.REFUND);
    }

    function test_duplicateBondIdReverts() public {
        _postBond();
        token.mint(funder, PRINCIPAL);
        vm.prank(funder);
        token.approve(address(ledger), PRINCIPAL);
        vm.prank(authorized);
        vm.expectRevert();
        ledger.postBond(BOND_ID, app, payer, funder, address(token), PRINCIPAL, bytes32(0), bytes32(0));
    }

    function test_unauthorizedPostReverts() public {
        token.mint(funder, PRINCIPAL);
        vm.prank(funder);
        token.approve(address(ledger), PRINCIPAL);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        ledger.postBond(BOND_ID, app, payer, funder, address(token), PRINCIPAL, bytes32(0), bytes32(0));
    }

    function test_unauthorizedSettleReverts() public {
        _postBond();
        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
        allocs[0] = IBondLedger.Allocation(payer, PRINCIPAL);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.REFUND);
    }

    function test_withFee_onlyNetStored() public {
        uint256 gross = PRINCIPAL + 0.1 ether;
        uint256 net = PRINCIPAL;
        token.mint(funder, gross);
        vm.prank(funder);
        token.approve(address(ledger), net);

        // Fee deducted before postBond - only net arrives
        vm.prank(authorized);
        ledger.postBond(BOND_ID, app, payer, funder, address(token), net, bytes32(0), bytes32(0));

        IBondLedger.BondPosition memory pos = ledger.getBond(BOND_ID);
        assertEq(pos.principal, net);
    }

    function test_claimFor_byAuthorized() public {
        _postBond();
        _settleRefund();

        uint256 before = token.balanceOf(payer);
        vm.prank(authorized);
        ledger.claimFor(BOND_ID, payer);
        assertEq(token.balanceOf(payer) - before, PRINCIPAL);
    }

    function test_zeroAllocationReverts() public {
        _postBond();
        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
        allocs[0] = IBondLedger.Allocation(payer, 0);
        vm.prank(authorized);
        vm.expectRevert();
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.REFUND);
    }

    function test_emptyAllocationsReverts() public {
        _postBond();
        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](0);
        vm.prank(authorized);
        vm.expectRevert();
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.REFUND);
    }

    // ── Helpers ──

    function _postBond() internal {
        token.mint(funder, PRINCIPAL);
        vm.prank(funder);
        token.approve(address(ledger), PRINCIPAL);
        vm.prank(authorized);
        ledger.postBond(BOND_ID, app, payer, funder, address(token), PRINCIPAL, bytes32(0), bytes32(0));
    }

    function _settleRefund() internal {
        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
        allocs[0] = IBondLedger.Allocation(payer, PRINCIPAL);
        vm.prank(authorized);
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.REFUND);
    }
}
