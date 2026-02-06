// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../../../../contracts/shared/interfaces/IIncentiveModule.sol';
import '../../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol';

/**
 * @title MockIncentiveModule
 * @notice Minimal mock for Foundry tests that need to assert incentive hooks were called
 */
contract MockIncentiveModule is IIncentiveModule {
    mapping(uint256 => bool) public onDisputeOpenedCalled;
    mapping(uint256 => uint256) public recordedWorkflowId;
    mapping(uint256 => address) public recordedToken;
    mapping(uint256 => uint256) public recordedAmount;
    mapping(uint256 => uint256) public recordedEscrowFee;
    mapping(uint256 => uint8) public recordedRound;

    function onDisputeOpened(
        uint256 workflowId,
        address /* escrowContract */,
        address token,
        uint256 amount,
        uint256 escrowFee,
        uint8 round
    ) external override {
        onDisputeOpenedCalled[workflowId] = true;
        recordedWorkflowId[workflowId] = workflowId;
        recordedToken[workflowId] = token;
        recordedAmount[workflowId] = amount;
        recordedEscrowFee[workflowId] = escrowFee;
        recordedRound[workflowId] = round;
    }

    // ---- The remaining interface methods are not used by this mock's tests ----

    function onResolverAssigned(uint256, address, address, uint8) external override {}

    function onDecisionSubmitted(
        uint256,
        address,
        address,
        uint8,
        ResolutionOutcome,
        uint256
    ) external override {}

    function onEscalated(uint256, address, uint8, uint8, address) external override {}

    function onDisputeFinalized(
        uint256,
        address,
        uint8,
        ResolutionOutcome
    ) external override {}

    function onResolverTimeout(uint256, address, address, uint8, uint8) external override {}

    function distributePayments(uint256, address, address, uint256) external override {}

    function getClaimablePayment(uint256, address, address) external pure override returns (uint256) {
        return 0;
    }

    function getRequiredAppealBond(uint256, address, uint8, uint8)
        external
        pure
        override
        returns (uint256, address)
    {
        return (0, address(0));
    }

    function recordAppealBond(uint256, address, address, address, uint256, address, uint8) external payable override {}

    function supportsFeature(bytes4) external pure override returns (bool) {
        return false;
    }

    function distributeAppealBond(uint256, address, uint8, bool) external override {}
}
