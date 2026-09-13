// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/shared/interfaces/IBondLedger.sol';
import '../../../contracts/shared/BondLedger.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

contract BondLedgerTest is Test {
    bytes32 constant REALIZED_DISTRIBUTION_V1 = keccak256('REALIZED_DISTRIBUTION_V1');
    bytes32 constant REALIZED_DISTRIBUTION_LEAF_V1 = keccak256('REALIZED_DISTRIBUTION_LEAF_V1');
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

    function test_settleBondWithRoot_recordsCanonicalDistributionAndCause() public {
        _postBond();
        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](2);
        allocs[0] = IBondLedger.Allocation(payer, PRINCIPAL / 2);
        allocs[1] = IBondLedger.Allocation(recipient, PRINCIPAL - PRINCIPAL / 2);
        _sortAllocations(allocs);
        bytes32 causeRoot = keccak256("final-ruling");

        vm.prank(authorized);
        ledger.settleBondWithRoot(
            BOND_ID,
            allocs,
            IBondLedger.SettlementKind.RESOLVER_PAYOUT,
            IBondLedger.DispositionCauseType.RULING_OUTCOME,
            causeRoot
        );

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encode(REALIZED_DISTRIBUTION_LEAF_V1, allocs[0].recipient, allocs[0].amount));
        leaves[1] = keccak256(abi.encode(REALIZED_DISTRIBUTION_LEAF_V1, allocs[1].recipient, allocs[1].amount));
        assertEq(
            ledger.getRealizedDistributionRoot(BOND_ID),
            keccak256(abi.encode(REALIZED_DISTRIBUTION_V1, 2, leaves))
        );
        assertEq(ledger.getAuthoritativeCauseRoot(BOND_ID), causeRoot);
        assertEq(
            uint256(ledger.getDispositionCauseType(BOND_ID)),
            uint256(IBondLedger.DispositionCauseType.RULING_OUTCOME)
        );
    }

    function test_positionRoles_preserveFunderBeneficiaryAndApplicationOperator() public {
        _postBond();
        IBondLedger.PositionRoles memory roles = ledger.getPositionRoles(BOND_ID);
        assertEq(roles.funder, funder);
        assertEq(roles.beneficiary, payer);
        assertEq(roles.operator, app);
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

    function test_terminalPosition_hasExactlyOneConservingDisposition() public {
        _postBond();
        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](2);
        allocs[0] = IBondLedger.Allocation(payer, PRINCIPAL / 3);
        allocs[1] = IBondLedger.Allocation(recipient, PRINCIPAL - PRINCIPAL / 3);
        _sortAllocations(allocs);

        vm.prank(authorized);
        ledger.settleBondWithRoot(
            BOND_ID,
            allocs,
            IBondLedger.SettlementKind.RESOLVER_PAYOUT,
            IBondLedger.DispositionCauseType.RULING_OUTCOME,
            keccak256("ruling-artifact")
        );

        IBondLedger.BondPosition memory pos = ledger.getBond(BOND_ID);
        IBondLedger.Allocation[] memory realized = ledger.getSettlementAllocations(BOND_ID);
        assertEq(uint256(pos.status), uint256(IBondLedger.BondStatus.SETTLED));
        assertEq(realized.length, 2);
        assertEq(realized[0].amount + realized[1].amount, pos.principal);
        assertTrue(ledger.getRealizedDistributionRoot(BOND_ID) != bytes32(0));

        vm.prank(authorized);
        vm.expectRevert();
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.RESOLVER_PAYOUT);
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

    function test_duplicateOrUnorderedRecipientsRevert() public {
        _postBond();
        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](2);
        allocs[0] = IBondLedger.Allocation(payer, PRINCIPAL / 2);
        allocs[1] = IBondLedger.Allocation(recipient, PRINCIPAL - PRINCIPAL / 2);
        _sortAllocations(allocs);
        (allocs[0], allocs[1]) = (allocs[1], allocs[0]);
        vm.prank(authorized);
        vm.expectRevert();
        ledger.settleBond(BOND_ID, allocs, IBondLedger.SettlementKind.RESOLVER_PAYOUT);
    }

    function test_goldenDistributionRoots_areStableAcrossCases() public {
        IBondLedger.Allocation[] memory single = new IBondLedger.Allocation[](1);
        single[0] = IBondLedger.Allocation(payer, PRINCIPAL);
        assertEq(
            ledger.realizedDistributionRoot(single),
            0x1e9aaaa8d91a44a2296c61fa0111fb7e59a9e5334a59237b887e4e0f4d957700
        );

        IBondLedger.Allocation[] memory split = new IBondLedger.Allocation[](2);
        split[0] = IBondLedger.Allocation(payer, 1);
        split[1] = IBondLedger.Allocation(recipient, type(uint256).max - 1);
        assertEq(
            ledger.realizedDistributionRoot(split),
            0xf0191ab9d770849c7a22889c654612ae1737003ee2b0b8061650d5f9ab91c337
        );

        IBondLedger.Allocation[] memory unsortedInput = new IBondLedger.Allocation[](3);
        unsortedInput[0] = IBondLedger.Allocation(address(0x03), 30);
        unsortedInput[1] = IBondLedger.Allocation(address(0x01), 10);
        unsortedInput[2] = IBondLedger.Allocation(address(0x02), 20);
        _sortThreeAllocations(unsortedInput);
        assertEq(unsortedInput[0].recipient, address(0x01));
        assertEq(unsortedInput[1].recipient, address(0x02));
        assertEq(unsortedInput[2].recipient, address(0x03));
        assertEq(
            ledger.realizedDistributionRoot(unsortedInput),
            0x0246c46f4482380a744f7c44d9a995b9d6cd843b30482e0374e48885ff0ae841
        );

        IBondLedger.Allocation[] memory remainder = new IBondLedger.Allocation[](3);
        remainder[0] = IBondLedger.Allocation(address(0x01), 34);
        remainder[1] = IBondLedger.Allocation(address(0x02), 33);
        remainder[2] = IBondLedger.Allocation(address(0x03), 33);
        assertEq(
            ledger.realizedDistributionRoot(remainder),
            0x5391c32b10d15e5648ff0cc32e8da0a881455b474727c7312be9db138f8f51bc
        );
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

    function _sortAllocations(IBondLedger.Allocation[] memory allocs) internal pure {
        if (allocs.length == 2 && allocs[0].recipient > allocs[1].recipient) {
            (allocs[0], allocs[1]) = (allocs[1], allocs[0]);
        }
    }

    function _sortThreeAllocations(IBondLedger.Allocation[] memory allocs) internal pure {
        for (uint256 i = 1; i < allocs.length; i++) {
            IBondLedger.Allocation memory current = allocs[i];
            uint256 j = i;
            while (j > 0 && allocs[j - 1].recipient > current.recipient) {
                allocs[j] = allocs[j - 1];
                j--;
            }
            allocs[j] = current;
        }
    }
}
