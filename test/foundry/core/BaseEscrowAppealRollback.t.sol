// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './AppealWindowEnforcement.t.sol';
import '../../mocks/MaliciousQuoteResolutionModule.sol';
import '../decentralized-resolution-module/mocks/MockIncentiveModule.sol';

contract BaseEscrowAppealRollbackTest is AppealWindowEnforcementTest {
    MaliciousQuoteResolutionModule internal maliciousModule;
    address internal constant SUCCESSOR = address(0xCAFE);
    uint256 internal constant BOND = 10 ether;

    function _installMaliciousModule(address incentive) internal {
        maliciousModule = new MaliciousQuoteResolutionModule(resolver1, incentive);
        adminContract.queueResolutionModule(address(escrow), address(maliciousModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(escrow));
    }

    function _prepareAppeal(address bondAsset, MaliciousQuoteResolutionModule.ExecuteBehavior behavior)
        internal returns (uint256 workflowId)
    {
        _installMaliciousModule(address(incentiveModule));
        maliciousModule.configure(SUCCESSOR, 1, bondAsset, BOND, behavior);
        workflowId = createEscrow();
        raiseDispute(workflowId);
        vm.prank(resolver1);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));
    }

    function _assertRollback(uint256 workflowId, uint256 buyerBalanceBefore, uint256 escrowBalanceBefore, uint256 collectorBalanceBefore) internal view {
        (bool pending,,,) = escrow.pendingSettlements(workflowId);
        (, uint8 level) = maliciousModule.getDisputeResolver(workflowId, address(escrow), bytes(''));
        assertTrue(pending, 'pending decision was not restored');
        assertEq(level, 0, 'module round changed');
        assertEq(escrow.addressEscalationCount(buyer), 0, 'escalation count changed');
        assertEq(escrow.claimableBondProtocolFees(address(token), feeAddress), 0, 'fee ledger changed');
        assertEq(token.balanceOf(buyer), buyerBalanceBefore, 'buyer ERC20 balance changed');
        assertEq(token.balanceOf(address(escrow)), escrowBalanceBefore, 'escrow ERC20 balance changed');
        assertEq(token.balanceOf(address(bondCollector)), collectorBalanceBefore, 'collector ERC20 balance changed');
        assertEq(incentiveModule.getAppealBond(workflowId, address(escrow), 1).amount, 0, 'bond was recorded');
    }

    function test_successorRoundMismatch_rollsBackFullAppeal() public {
        uint256 workflowId = _prepareAppeal(address(token), MaliciousQuoteResolutionModule.ExecuteBehavior.ROUND_MISMATCH);
        vm.prank(buyer);
        token.approve(address(escrow), BOND);
        uint256 buyerBalance = token.balanceOf(buyer);
        uint256 escrowBalance = token.balanceOf(address(escrow));
        uint256 collectorBalance = token.balanceOf(address(bondCollector));

        vm.expectRevert(abi.encodeWithSignature('EscalationResultMismatch(uint8,uint8,address,address)', uint8(1), uint8(2), SUCCESSOR, SUCCESSOR));
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        _assertRollback(workflowId, buyerBalance, escrowBalance, collectorBalance);
    }

    function test_successorResolverMismatch_rollsBackFullAppeal() public {
        uint256 workflowId = _prepareAppeal(address(token), MaliciousQuoteResolutionModule.ExecuteBehavior.RESOLVER_MISMATCH);
        vm.prank(buyer);
        token.approve(address(escrow), BOND);
        uint256 buyerBalance = token.balanceOf(buyer);
        uint256 escrowBalance = token.balanceOf(address(escrow));
        uint256 collectorBalance = token.balanceOf(address(bondCollector));

        vm.expectRevert(abi.encodeWithSignature('EscalationResultMismatch(uint8,uint8,address,address)', uint8(1), uint8(1), SUCCESSOR, address(0xBEEF)));
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        _assertRollback(workflowId, buyerBalance, escrowBalance, collectorBalance);
    }

    function test_erc20ExecuteRevertAfterCustody_rollsBackFullAppeal() public {
        uint256 workflowId = _prepareAppeal(address(token), MaliciousQuoteResolutionModule.ExecuteBehavior.REVERT);
        vm.prank(buyer);
        token.approve(address(escrow), BOND);
        uint256 buyerBalance = token.balanceOf(buyer);
        uint256 escrowBalance = token.balanceOf(address(escrow));
        uint256 collectorBalance = token.balanceOf(address(bondCollector));

        vm.expectRevert(bytes('malicious execute revert'));
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        _assertRollback(workflowId, buyerBalance, escrowBalance, collectorBalance);
    }

    function test_erc20IncentiveRecordRevertAfterBondCollectorCustody_rollsBackFullAppeal() public {
        MockIncentiveModule revertingIncentive = new MockIncentiveModule();
        revertingIncentive.setRevertOnRecordAppealBond(true);
        _installMaliciousModule(address(revertingIncentive));
        maliciousModule.configure(SUCCESSOR, 1, address(token), BOND, MaliciousQuoteResolutionModule.ExecuteBehavior.SUCCESS);
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);
        vm.prank(resolver1);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));
        vm.prank(buyer);
        token.approve(address(escrow), BOND);
        uint256 buyerBalance = token.balanceOf(buyer);
        uint256 escrowBalance = token.balanceOf(address(escrow));
        uint256 collectorBalance = token.balanceOf(address(bondCollector));

        vm.expectRevert(MockIncentiveModule.RecordAppealBondReverted.selector);
        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        _assertRollback(workflowId, buyerBalance, escrowBalance, collectorBalance);
        assertEq(token.allowance(address(bondCollector), address(revertingIncentive)), 0, 'collector allowance changed');
    }

    function test_erc20AppealFeeLiabilityIsPhysicallyBacked() public {
        escrow.setAppealBondProtocolFeeBps(500);
        uint256 workflowId = _prepareAppeal(address(token), MaliciousQuoteResolutionModule.ExecuteBehavior.SUCCESS);
        uint256 escrowBalanceBefore = token.balanceOf(address(escrow));
        uint256 expectedFee = BOND * 500 / escrow.ESCROW_FEE_DENOMINATOR();
        vm.prank(buyer);
        token.approve(address(escrow), BOND);

        vm.prank(buyer);
        escrow.escalateDispute(workflowId);

        uint256 liability = escrow.claimableBondProtocolFees(address(token), feeAddress);
        assertEq(liability, expectedFee, 'incorrect ERC20 fee liability');
        assertEq(token.balanceOf(address(escrow)) - escrowBalanceBefore, liability, 'ERC20 liability is not physically backed');
    }

    function test_ethAppealFeeLiabilityIsPhysicallyBacked() public {
        escrow.setAppealBondProtocolFeeBps(500);
        MockIncentiveModule ethIncentive = new MockIncentiveModule();
        _installMaliciousModule(address(ethIncentive));
        maliciousModule.configure(SUCCESSOR, 1, address(0), BOND, MaliciousQuoteResolutionModule.ExecuteBehavior.SUCCESS);
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);
        vm.prank(resolver1);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));
        uint256 escrowBalanceBefore = address(escrow).balance;
        uint256 expectedFee = BOND * 500 / escrow.ESCROW_FEE_DENOMINATOR();
        vm.deal(buyer, BOND);

        vm.prank(buyer);
        escrow.escalateDispute{value: BOND}(workflowId);

        uint256 liability = escrow.claimableBondProtocolFees(address(0), feeAddress);
        assertEq(liability, expectedFee, 'incorrect ETH fee liability');
        assertEq(address(escrow).balance - escrowBalanceBefore, liability, 'ETH liability is not physically backed');
    }

    function test_ethExecuteRevertAfterCustody_rollsBackFullAppeal() public {
        MockIncentiveModule ethIncentive = new MockIncentiveModule();
        _installMaliciousModule(address(ethIncentive));
        maliciousModule.configure(SUCCESSOR, 1, address(0), BOND, MaliciousQuoteResolutionModule.ExecuteBehavior.REVERT);
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);
        vm.prank(resolver1);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));
        vm.deal(buyer, BOND);
        uint256 buyerBalance = buyer.balance;
        uint256 escrowBalance = address(escrow).balance;
        uint256 incentiveBalance = address(ethIncentive).balance;

        vm.expectRevert(bytes('malicious execute revert'));
        vm.prank(buyer);
        escrow.escalateDispute{value: BOND}(workflowId);

        assertEq(buyer.balance, buyerBalance, 'buyer ETH balance changed');
        assertEq(address(escrow).balance, escrowBalance, 'escrow ETH balance changed');
        assertEq(address(ethIncentive).balance, incentiveBalance, 'incentive ETH balance changed');
        assertEq(escrow.addressEscalationCount(buyer), 0, 'escalation count changed');
        (bool pending,,,) = escrow.pendingSettlements(workflowId);
        assertTrue(pending, 'pending decision was not restored');
    }
}
