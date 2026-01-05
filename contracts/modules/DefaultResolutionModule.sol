// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IResolutionModule.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title DefaultResolutionModule
 * @notice Default resolution module: single resolver, no escalation
 * @dev Pluggable module intended to be selected by governance and used by the escrow contract
 *      to choose the per-escrow disputeResolver at escrow creation time.
 */
contract DefaultResolutionModule is AccessControl, IResolutionModule {
    // Role constants for governance
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    address public resolver;

    event ResolverUpdated(address indexed oldResolver, address indexed newResolver);

    constructor(address initialOwner, address initialResolver) {
        resolver = initialResolver;
        // Grant DEFAULT_ADMIN_ROLE to initialOwner so roles can be granted later
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    function setResolver(address newResolver) external onlyRole(ROLE_TIMELOCK) {
        address oldResolver = resolver;
        resolver = newResolver;
        emit ResolverUpdated(oldResolver, newResolver);
    }

    /**
     * @notice Check if address is authorized resolver
     * @dev In default implementation, checks against stored resolver
     */
    function isAuthorizedResolver(
        uint256 /* workflowId */,
        address checkResolver,
        bytes calldata /* escrowData */
    ) external view override returns (bool authorized, uint8 role) {
        // Check if the resolver matches the stored resolver
        authorized = (checkResolver == resolver);
        role = 0;
        return (authorized, role);
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
     * @dev AccessControl already includes ERC165
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControl, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IResolutionModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}


