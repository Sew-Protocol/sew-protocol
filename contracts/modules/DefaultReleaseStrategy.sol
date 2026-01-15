// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "../interfaces/IReleaseStrategy.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * @title DefaultReleaseStrategy
 * @notice Default release strategy: buyer-initiated release
 * @dev This matches the current behavior of EscrowableERC20
 */
contract DefaultReleaseStrategy is IReleaseStrategy, ERC165 {
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
    
    /**
     * @notice Get the module name (alias for strategyName for consistency)
     * @return name The module name
     */
    function moduleName() external pure override returns (string memory name) {
        return "DefaultBuyerRelease";
    }
    
    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning)
     */
    function moduleVersion() external pure override returns (string memory version) {
        return "1.0.0";
    }
    
    /**
     * @notice Check if contract supports an interface
     * @param interfaceId The interface identifier
     * @return supported True if interface is supported
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IReleaseStrategy).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}



