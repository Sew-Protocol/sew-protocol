// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

/**
 * @title ModuleProposalLibrary
 * @notice Library for module proposal and activation pattern
 * @dev Extracted from BaseEscrow for contract size reduction
 *      Returns values instead of modifying storage (caller updates storage)
 */
library ModuleProposalLibrary {
    /**
     * @notice Calculate ETA for module proposal
     * @param delay Delay in seconds before activation is allowed
     * @return eta Timestamp when activation will be allowed
     */
    function calculateProposalEta(uint256 delay) internal view returns (uint256 eta) {
        return block.timestamp + delay;
    }

    /**
     * @notice Validate module proposal
     * @param newModule New module address to propose
     * @param currentModule Current module address
     * @dev Reverts if module is invalid
     */
    function validateProposal(address newModule, address currentModule) internal pure {
        require(newModule != address(0), "Zero module address");
        require(newModule != currentModule, "Module already active");
    }

    /**
     * @notice Validate module activation
     * @param pendingModule Pending module address
     * @param pendingEta Pending ETA timestamp
     * @dev Reverts if activation is not allowed
     */
    function validateActivation(address pendingModule, uint256 pendingEta) internal view {
        require(block.timestamp >= pendingEta, "Delay not elapsed");
        require(pendingModule != address(0), "No pending module");
    }
}




