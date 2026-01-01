// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IReleaseStrategy.sol";

/**
 * @title DefaultReleaseStrategy
 * @notice Default release strategy: buyer-initiated release
 * @dev This matches the current behavior of EscrowableERC20
 */
contract DefaultReleaseStrategy is IReleaseStrategy {
    /**
     * @notice Check if release is allowed (only sender can release)
     */
    function canRelease(
        uint256 /* workflowId */,
        address /* caller */,
        bytes calldata /* escrowData */
    ) external pure override returns (bool allowed, string memory reason) {
        // Decode escrow data to get sender address
        // For now, we'll use a simple check - in full implementation, decode the struct
        // This is a placeholder that always allows (actual validation in main contract)
        return (true, "");
    }

    /**
     * @notice Execute release (returns recipient and amount)
     */
    function executeRelease(
        uint256 /* workflowId */,
        bytes calldata /* escrowData */
    ) external pure override returns (bool success, address recipient, uint256 amount) {
        // This is a placeholder - actual release logic handled by main contract
        // In full implementation, would decode escrowData and return recipient/amount
        return (true, address(0), 0);
    }

    /**
     * @notice Get strategy name
     */
    function strategyName() external pure override returns (string memory) {
        return "DefaultBuyerRelease";
    }
}



