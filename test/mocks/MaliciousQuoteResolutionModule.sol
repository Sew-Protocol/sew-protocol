// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../../contracts/shared/interfaces/IResolutionModule.sol';
import '../../contracts/shared/interfaces/IIncentiveModule.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

/// @dev Test-only module that returns a valid appeal quote but misbehaves on execution.
contract MaliciousQuoteResolutionModule is IResolutionModule, ERC165 {
    enum ExecuteBehavior { SUCCESS, ROUND_MISMATCH, RESOLVER_MISMATCH, REVERT }

    address public resolver;
    address public successorResolver;
    address public incentiveModule;
    address public bondAsset;
    uint256 public bondAmount;
    uint8 public successorRound;
    ExecuteBehavior public executeBehavior;
    mapping(uint256 => uint8) public currentRound;
    mapping(uint256 => address) public currentResolver;

    constructor(address resolver_, address incentiveModule_) {
        resolver = resolver_;
        incentiveModule = incentiveModule_;
    }

    function configure(address successorResolver_, uint8 successorRound_, address bondAsset_, uint256 bondAmount_, ExecuteBehavior behavior_) external {
        successorResolver = successorResolver_;
        successorRound = successorRound_;
        bondAsset = bondAsset_;
        bondAmount = bondAmount_;
        executeBehavior = behavior_;
    }

    function initializeDispute(uint256, address, address, bytes32) external override {}
    function recordResolution(uint256, address, address, ResolutionOutcome, uint256) external override {}

    function isAuthorizedDisputeResolver(uint256, address, address potentialResolver, bytes calldata)
        external view override returns (bool, uint8)
    {
        return (potentialResolver == resolver, 0);
    }

    function getDisputeResolver(uint256 workflowId, address, bytes calldata) external view override returns (address, uint8) {
        address current = currentResolver[workflowId];
        return (current == address(0) ? resolver : current, currentRound[workflowId]);
    }

    function canEscalate(uint256, address, uint8, bytes calldata) external view override returns (bool, address, uint256) {
        return (true, successorResolver, bondAmount);
    }

    function executeEscalation(uint256, address, bytes calldata) external pure override returns (bool, address, uint8) {
        return (false, address(0), 0);
    }

    function quoteAppealTransition(uint256 workflowId, address escrowContract, bytes calldata)
        external view override returns (ResolutionAppealQuote memory quote)
    {
        quote.appealable = true;
        quote.predecessorRound = 0;
        quote.successorRound = successorRound;
        quote.predecessorResolver = resolver;
        quote.successorResolver = successorResolver;
        quote.appealedDecision = ResolutionOutcome.RELEASE;
        quote.appealDeadline = block.timestamp + 1 days;
        quote.baseBondAsset = bondAsset;
        quote.baseBondAmount = bondAmount;
        quote.appealedDecisionRoot = keccak256(abi.encode(workflowId, escrowContract, resolver));
        quote.resolutionQuoteRoot = keccak256(abi.encode(
            workflowId, escrowContract, resolver, successorResolver, successorRound, bondAsset, bondAmount
        ));
    }

    function executeEscalationWithQuote(uint256 workflowId, address escrowContract, bytes calldata, bytes32 expectedRoot)
        external override returns (bool, address, uint8)
    {
        if (executeBehavior == ExecuteBehavior.REVERT) revert('malicious execute revert');
        bytes32 root = keccak256(abi.encode(
            workflowId, escrowContract, resolver, successorResolver, successorRound, bondAsset, bondAmount
        ));
        require(expectedRoot == root, 'unexpected quote root');
        if (executeBehavior == ExecuteBehavior.ROUND_MISMATCH) {
            currentRound[workflowId] = successorRound + 1;
            currentResolver[workflowId] = successorResolver;
            return (true, successorResolver, successorRound + 1);
        }
        if (executeBehavior == ExecuteBehavior.RESOLVER_MISMATCH) {
            currentRound[workflowId] = successorRound;
            currentResolver[workflowId] = address(0xBEEF);
            return (true, address(0xBEEF), successorRound);
        }
        currentRound[workflowId] = successorRound;
        currentResolver[workflowId] = successorResolver;
        return (true, successorResolver, successorRound);
    }

    function getRequiredAppealBond(uint256, address, uint8, bytes calldata) external view override returns (uint256, address) {
        return (bondAmount, bondAsset);
    }

    function getDecisionAtRound(uint256, address, uint8) external pure override returns (uint8) {
        return uint8(ResolutionOutcome.RELEASE);
    }

    function getAppealDeadlineAndRound(uint256, address) external view override returns (uint256, uint8, bool) {
        return (block.timestamp + 1 days, 0, false);
    }

    function recordReversal(uint256, address, uint8) external override {}
    function finalizeDispute(uint256, address) external override {}
    function moduleName() external pure override returns (string memory) { return 'MaliciousQuoteResolutionModule'; }
    function moduleVersion() external pure override returns (string memory) { return '1.0.0'; }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IResolutionModule).interfaceId || super.supportsInterface(interfaceId);
    }
}
