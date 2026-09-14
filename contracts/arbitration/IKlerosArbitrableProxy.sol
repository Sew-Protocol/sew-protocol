// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

interface IKlerosArbitrableProxy {
    function getArbitrationCost(bytes calldata extraData) external view returns (uint256);
    function getKlerosHandoffConfigRoot() external view returns (bytes32);

    function createDispute(
        uint256 workflowId,
        address escrowContract,
        uint256 choices,
        bytes calldata extraData,
        bytes calldata escrowData
    ) external payable returns (uint256 klerosDisputeId);
}
