// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import './AppealWindowEnforcement.t.sol';
import '../../../contracts/core/EscrowableERC20.sol';
import '../../../contracts/interfaces/IEscrowLifecycle.sol';
import '../../../contracts/interfaces/IEscrowDispute.sol';
import '../../../contracts/interfaces/IEscrowAppeal.sol';
import '../../../contracts/interfaces/IEscrowSettlement.sol';
import '../../../contracts/interfaces/IEscrowViews.sol';

contract WalletEscrowCapabilitiesTest is AppealWindowEnforcementTest {
    function test_supportsWalletCapabilityInterfaces() public view {
        assertTrue(escrow.supportsInterface(type(IEscrowLifecycle).interfaceId));
        assertTrue(escrow.supportsInterface(type(IEscrowDispute).interfaceId));
        assertTrue(escrow.supportsInterface(type(IEscrowAppeal).interfaceId));
        assertTrue(escrow.supportsInterface(type(IEscrowSettlement).interfaceId));
        assertTrue(escrow.supportsInterface(type(IEscrowViews).interfaceId));
        assertFalse(escrow.supportsInterface(0xffffffff));
    }

    function test_escrowableERC20_supportsWalletCapabilityInterfaces() public {
        EscrowableERC20 escrowToken = new EscrowableERC20('Escrow Token','ESC',ESCROW_FEE,feeAddress,address(yieldOps),address(moduleManagement));
        assertTrue(escrowToken.supportsInterface(type(IEscrowLifecycle).interfaceId));
        assertTrue(escrowToken.supportsInterface(type(IEscrowDispute).interfaceId));
        assertTrue(escrowToken.supportsInterface(type(IEscrowAppeal).interfaceId));
        assertTrue(escrowToken.supportsInterface(type(IEscrowSettlement).interfaceId));
        assertTrue(escrowToken.supportsInterface(type(IEscrowViews).interfaceId));
    }

    function test_getAppealQuote_marksCustomResolverWorkflowUnsupported() public {
        vm.startPrank(buyer);
        token.approve(address(escrow), ESCROW_AMOUNT);
        uint256 workflowId = escrow.createEscrow(address(token), seller, ESCROW_AMOUNT, EscrowSettings({
            customResolver: address(resolutionModule), releaseAddress: address(0), yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0, autoCancelTime: 0
        }));
        vm.stopPrank();

        IEscrowAppeal.AppealQuote memory quote = escrow.getAppealQuote(workflowId, buyer);
        assertFalse(quote.supported);
        assertFalse(quote.appealable);
    }

    function test_getAppealQuote_matchesAppealExecutionEconomics() public {
        escrow.setAppealBondProtocolFeeBps(500);
        uint256 workflowId = createEscrow();
        raiseDispute(workflowId);
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            address(token), buyer, seller, ESCROW_AMOUNT, address(0)
        );
        (address resolver,) = resolutionModule.getDisputeResolver(workflowId, address(escrow), escrowData);
        vm.prank(resolver);
        escrow.releaseAsDisputeResolver(workflowId, bytes32(0));

        IEscrowAppeal.AppealQuote memory quote = escrow.getAppealQuote(workflowId, buyer);
        assertTrue(quote.supported);
        assertTrue(quote.appealable);
        assertEq(quote.protocolFeeBps, 500);
        assertEq(quote.bondAmount, quote.protocolFeeAmount + quote.bondToRecord);
        vm.prank(buyer);
        token.approve(address(escrow), quote.bondAmount);

        uint256 feeBefore = escrow.claimableBondProtocolFees(quote.bondAsset, quote.protocolFeeRecipient);
        vm.prank(buyer);
        (bool success, address newResolver, uint8 newLevel) = escrow.escalateDispute(workflowId);

        assertTrue(success);
        assertEq(newResolver, quote.successorResolver);
        assertEq(newLevel, quote.successorRound);
        assertEq(
            escrow.claimableBondProtocolFees(quote.bondAsset, quote.protocolFeeRecipient) - feeBefore,
            quote.protocolFeeAmount
        );
        assertEq(incentiveModule.getAppealBond(workflowId, address(escrow), newLevel).amount, quote.bondToRecord);
    }
}
