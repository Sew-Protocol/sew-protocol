// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import '../types/EscrowTypes.sol';

/// @notice Wallet-discoverable appeal actions and their normalized quote.
interface IEscrowAppeal is IERC165 {
    /// @dev Kept explicit so an approval cannot be redirected from its caller.
    struct AppealRequest {
        address funder;
        address operator;
        address refundRecipient;
    }

    /// @notice Module transition facts combined with escrow-snapshotted bond economics.
    /// @dev `supported` is false for workflows using a custom resolver, whose appeal
    ///      flow is intentionally not implemented by this capability.
    struct AppealQuote {
        bool supported;
        bool appealable;
        uint8 predecessorRound;
        uint8 successorRound;
        address predecessorResolver;
        address successorResolver;
        ResolutionOutcome appealedDecision;
        uint256 appealDeadline;
        bool finalRound;
        address bondAsset;
        uint256 baseBondAmount;
        uint256 bondAmount;
        uint256 protocolFeeAmount;
        uint256 bondToRecord;
        uint256 protocolFeeBps;
        address protocolFeeRecipient;
        bytes32 appealedDecisionRoot;
        bytes32 resolutionQuoteRoot;
    }

    function getAppealQuote(uint256 workflowId, address operator) external view returns (AppealQuote memory quote);
    function escalateDispute(uint256 workflowId)
        external payable returns (bool success, address newDisputeResolver, uint8 newLevel);
    function appealDispute(uint256 workflowId, AppealRequest calldata request)
        external payable returns (bool success, address newDisputeResolver, uint8 newLevel);
}
