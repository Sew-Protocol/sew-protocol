// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IResolver.sol';
import '../types/EscrowTypes.sol';
import '../modules/decentralized-resolution-module/interfaces/IKlerosHandoffResolutionModule.sol';
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title DisputeInitializationLibrary
 * @notice Library for dispute initialization logic
 */
library DisputeInitializationLibrary {
    error DisputeModuleInitializationFailed(address module, uint256 workflowId);
    error InvalidAssignedResolver(uint256 workflowId, address resolver);
    error UnauthorizedResolverModule(address caller, address expectedModule);
    event DisputeResolverSynchronized(uint256 indexed workflowId, address indexed resolver);
    /**
     * @dev Initialize dispute in resolution module
     * @param disputeResolutionModule Dispute resolution module address
     * @param workflowId Escrow workflow ID
     * @param disputeResolver Dispute resolver address
     * @param escrowData Encoded escrow data
     * @return configVersion Bound DRM config version, or zero for legacy modules
     */
    function initializeInModule(
        address disputeResolutionModule,
        uint256 workflowId,
        address disputeResolver,
        uint256 configVersion,
        bytes memory escrowData
    ) public returns (uint256) {
        if (disputeResolutionModule == address(0)) {
            return 0;
        }

        if (configVersion != 0) {
                (bool configInitialized, bytes memory returnData) = disputeResolutionModule.call(
                    abi.encodeWithSignature(
                        'initializeDisputeWithCategoryAndConfig(uint256,address,bytes,uint256)',
                        workflowId,
                        address(this),
                        escrowData,
                        configVersion
                    )
                );
                if (configInitialized) return configVersion;
                // A config-bound workflow must never silently initialize against a
                // different/default policy, including after its policy is deprecated.
                assembly ("memory-safe") {
                    revert(add(returnData, 32), mload(returnData))
                }
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
                    return 0;
                }
            } catch {}
            return 0;
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
                    return 0;
                }
            } catch {}
        }

        revert DisputeModuleInitializationFailed(disputeResolutionModule, workflowId);
    }

    /**
     * @dev Call dispute resolver callback if it implements IResolver
     * @param disputeResolver Dispute resolver address
     * @param workflowId Escrow workflow ID
     */
    function callResolverCallback(address disputeResolver, uint256 workflowId) public {
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

    /**
     * @dev Read back the resolver selected by a resolution module after initialization.
     *      A config-bound workflow must have a nonzero assignment; legacy modules may
     *      omit this view and retain the resolver supplied before initialization.
     */
    function synchronizeAssignedResolver(
        address disputeResolutionModule,
        uint256 workflowId,
        bytes memory escrowData,
        uint256 configVersion,
        address currentResolver
    ) public view returns (address assignedResolver) {
        try IResolutionModule(disputeResolutionModule).getDisputeResolver(
            workflowId, address(this), escrowData
        ) returns (address resolver, uint8) {
            if (resolver != address(0)) return resolver;
            if (configVersion != 0) revert InvalidAssignedResolver(workflowId, resolver);
        } catch {
            if (configVersion != 0) revert InvalidAssignedResolver(workflowId, address(0));
        }
        return currentResolver;
    }

    /**
     * @dev Apply an authenticated assignment transition to escrow storage. This public
     *      library call runs by delegatecall, so the storage writes and event belong to
     *      the escrow while the original resolution module remains msg.sender.
     */
    function updateDisputeResolverFromModule(
        EscrowTransfer[] storage escrowTransfers,
        mapping(uint256 => EscrowSettings) storage escrowSettings,
        uint256 workflowId,
        address resolver,
        address expectedModule
    ) public {
        if (msg.sender != expectedModule) revert UnauthorizedResolverModule(msg.sender, expectedModule);
        EscrowTransfer storage transfer = escrowTransfers[workflowId];
        if (transfer.escrowState != EscrowState.DISPUTED) {
            revert InvalidAssignedResolver(workflowId, resolver);
        }
        if (escrowSettings[workflowId].customResolver != address(0)) return;
        transfer.disputeResolver = resolver;
        emit DisputeResolverSynchronized(workflowId, resolver);
    }

    function committedKlerosHandoff(address module, address escrow, uint256 workflowId)
        public
        view
        returns (bool committed, uint256 disputeId)
    {
        if (module == address(0)) return (false, 0);
        try IKlerosHandoffResolutionModule(module).getCommittedKlerosDisputeId(escrow, workflowId)
            returns (bool hasHandoff, uint256 id)
        {
            return (hasHandoff, id);
        } catch {
            return (false, 0);
        }
    }
}
