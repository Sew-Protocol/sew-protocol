// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IResolver.sol';
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title DisputeInitializationLibrary
 * @notice Library for dispute initialization logic
 * @dev Extracted from BaseEscrow to reduce contract size
 */
library DisputeInitializationLibrary {
    /**
     * @dev Initialize dispute in resolution module
     * @param disputeResolutionModule Dispute resolution module address
     * @param workflowId Escrow workflow ID
     * @param disputeResolver Dispute resolver address
     * @param escrowData Encoded escrow data
     * @return updatedDisputeResolver Updated dispute resolver address (may be different if module reassigns)
     */
    function initializeInModule(
        address disputeResolutionModule,
        uint256 workflowId,
        address disputeResolver,
        bytes memory escrowData
    ) internal returns (address updatedDisputeResolver) {
        if (disputeResolutionModule == address(0)) {
            return disputeResolver;
        }

        // Try initializeDisputeWithCategory first
        (bool success1, ) = disputeResolutionModule.call(
            abi.encodeWithSignature(
                'initializeDisputeWithCategory(uint256,address,bytes)',
                workflowId,
                address(this),
                escrowData
            )
        );

        if (success1) {
            // Try to get updated dispute resolver from module
            try
                IResolutionModule(disputeResolutionModule).getDisputeResolver(
                    workflowId,
                    address(this),
                    escrowData
                )
            returns (address moduleDisputeResolver, uint8) {
                if (moduleDisputeResolver != address(0)) {
                    return moduleDisputeResolver;
                }
            } catch {}
            return disputeResolver;
        }

        // Fallback: try initializeDispute
        (bool success2, ) = disputeResolutionModule.call(
            abi.encodeWithSignature(
                'initializeDispute(uint256,address,address,bytes32)',
                workflowId,
                address(this),
                disputeResolver,
                bytes32(0)
            )
        );

        if (success2) {
            try
                IResolutionModule(disputeResolutionModule).getDisputeResolver(
                    workflowId,
                    address(this),
                    escrowData
                )
            returns (address moduleDisputeResolver, uint8) {
                if (moduleDisputeResolver != address(0)) {
                    return moduleDisputeResolver;
                }
            } catch {}
        }

        return disputeResolver;
    }

    /**
     * @dev Call dispute resolver callback if it implements IResolver
     * @param disputeResolver Dispute resolver address
     * @param workflowId Escrow workflow ID
     */
    function callResolverCallback(address disputeResolver, uint256 workflowId) internal {
        if (disputeResolver.code.length == 0) {
            return; // Not a contract
        }

        try IERC165(disputeResolver).supportsInterface(type(IResolver).interfaceId) returns (
            bool supported
        ) {
            if (supported) {
                try IResolver(disputeResolver).onDisputeOpened(workflowId, '') {
                    // Callback succeeded
                } catch {
                    // Callback failed, but don't revert
                }
            }
        } catch {
            // Not an IResolver contract
        }
    }
}
