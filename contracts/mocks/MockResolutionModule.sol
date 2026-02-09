// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'contracts/shared/interfaces/IResolutionModule.sol';

import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

contract MockResolutionModule is IResolutionModule, ERC165 {
    function initializeDispute(
        uint256 workflowId,
        address escrowContract,
        address initialResolver,
        bytes32 categoryKey
    ) external override {
        workflowId; escrowContract; initialResolver; categoryKey; // Unused
    }

    function recordResolution(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        ResolutionOutcome outcome,
        uint256 resolutionTime
    ) external override {
        workflowId; escrowContract; resolver; outcome; resolutionTime; // Unused
    }

    function isAuthorizedDisputeResolver(
        uint256 workflowId,
        address escrowContract,
        address potentialResolver,
        bytes calldata escrowData
    ) external view override returns (bool authorized, uint8 role) {
        workflowId; escrowContract; escrowData; // Unused
        // For testing, let's say the deployer of the mock is the authorized resolver
        // and also the resolver passed to getDisputeResolver.
        return (potentialResolver == msg.sender || potentialResolver == address(this), 0);
    }

    function getDisputeResolver(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external view override returns (address resolver, uint8 escalationLevel) {
        workflowId; escrowContract; escrowData; // Unused
        return (address(this), 0); // Always return mock itself as resolver
    }

    function canEscalate(
        uint256 workflowId,
        address escrowContract,
        uint8 currentLevel,
        bytes calldata escrowData
    ) external view override returns (bool canEscalate, address nextDisputeResolver, uint256 escalationFee) {
        workflowId; escrowContract; currentLevel; escrowData; // Unused
        return (false, address(0), 0); // Cannot escalate
    }

    function executeEscalation(
        uint256 workflowId,
        address escrowContract,
        bytes calldata escrowData
    ) external override returns (bool success, address newDisputeResolver, uint8 newLevel) {
        workflowId; escrowContract; escrowData; // Unused
        return (false, address(0), 0); // Cannot escalate
    }

    function getRequiredAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 currentLevel,
        bytes calldata escrowData
    ) external view override returns (uint256 amount, address token) {
        workflowId; escrowContract; currentLevel; escrowData; // Unused
        return (0, address(0)); // No bond required
    }

    function getDecisionAtRound(uint256 workflowId, address escrowContract, uint8 round) external view override returns (uint8 decision) {
        workflowId; escrowContract; round; // Unused
        return uint8(ResolutionOutcome.NONE);
    }

    function getAppealDeadlineAndRound(
        uint256 workflowId,
        address escrowContract
    ) external view override returns (uint256 appealDeadline, uint8 currentRound, bool isFinalRound) {
        workflowId; escrowContract; // Unused
        return (0, 0, true);
    }

    function recordReversal(uint256 workflowId, address escrowContract, uint8 priorRound) external override {
        workflowId; escrowContract; priorRound; // Unused
    }

    function finalizeDispute(uint256 workflowId, address escrowContract) external override {
        workflowId; escrowContract; // Unused
    }

    function moduleName() external pure override returns (string memory) {
        return "MockResolutionModule";
    }

    function moduleVersion() external pure override returns (string memory) {
        return "1.0.0";
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IResolutionModule).interfaceId || super.supportsInterface(interfaceId);
    }
}
