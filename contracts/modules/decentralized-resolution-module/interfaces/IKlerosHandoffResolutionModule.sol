// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

interface IKlerosHandoffResolutionModule {
    function prepareKlerosHandoff(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData,
        bytes32 resolutionQuoteRoot,
        bytes32 klerosConfigRoot
    ) external returns (bytes32 handoffRoot);

    function commitKlerosHandoff(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData,
        bytes32 resolutionQuoteRoot,
        bytes32 handoffRoot,
        bytes32 klerosConfigRoot,
        uint256 klerosDisputeId
    ) external returns (bool success, address newResolver, uint8 newLevel);

    function getCommittedKlerosDisputeId(address escrowContract, uint256 workflowId)
        external view returns (bool committed, uint256 klerosDisputeId);

    function getCommittedKlerosConfigRoot(address escrowContract, uint256 workflowId)
        external view returns (bytes32);
}
