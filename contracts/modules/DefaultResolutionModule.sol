// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IResolutionModule.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DefaultResolutionModule
 * @notice Default resolution module: single resolver, no escalation
 * @dev Pluggable module intended to be selected by governance and used by the escrow contract
 *      to choose the per-escrow disputeResolver at escrow creation time.
 */
contract DefaultResolutionModule is Ownable, IResolutionModule {
    address public resolver;

    event ResolverUpdated(address indexed oldResolver, address indexed newResolver);

    constructor(address initialOwner, address initialResolver) Ownable(initialOwner) {
        resolver = initialResolver;
    }

    function setResolver(address newResolver) external onlyOwner {
        address oldResolver = resolver;
        resolver = newResolver;
        emit ResolverUpdated(oldResolver, newResolver);
    }

    /**
     * @notice Check if address is authorized resolver
     * @dev In default implementation, checks against authorizedResolver
     * This is a placeholder - actual check happens in main contract
     */
    function isAuthorizedResolver(
        uint256 /* workflowId */,
        address /* resolver */,
        bytes calldata /* escrowData */
    ) external pure override returns (bool authorized, uint8 role) {
        // Advisory only; escrow contract should authorize based on the escrow's stored disputeResolver.
        return (true, 0);
    }

    /**
     * @notice Get resolver for dispute
     */
    function getResolver(
        uint256 /* workflowId */,
        bytes calldata /* escrowData */
    ) external view override returns (address resolver_, uint8 escalationLevel) {
        return (resolver, 0);
    }

    /**
     * @notice Check if escalation is allowed (default: no escalation)
     */
    function canEscalate(
        uint256 /* workflowId */,
        uint8 /* currentLevel */,
        bytes calldata /* escrowData */
    ) external pure override returns (
        bool allowed,
        address nextResolver,
        uint256 escalationFee
    ) {
        return (false, address(0), 0);
    }

    /**
     * @notice Execute escalation (default: not supported)
     */
    function executeEscalation(
        uint256 /* workflowId */,
        bytes calldata /* escrowData */
    ) external pure override returns (
        bool success,
        address newResolver,
        uint8 newLevel
    ) {
        return (false, address(0), 0);
    }

    /**
     * @notice Get module name
     */
    function moduleName() external pure override returns (string memory) {
        return "DefaultSingleResolver";
    }
}


