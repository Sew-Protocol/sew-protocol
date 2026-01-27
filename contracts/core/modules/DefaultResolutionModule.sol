// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../../shared/interfaces/IResolutionModule.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '../../types/EscrowTypes.sol';

/**
 * @title DefaultResolutionModule
 * @notice Default resolution module: single resolver, no escalation
 * @dev Pluggable module intended to be selected by governance and used by the escrow contract
 *      to choose the per-escrow disputeResolver at escrow creation time.
 */
contract DefaultResolutionModule is AccessControl, IResolutionModule {
    // Role constants for governance
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    address public resolver;

    event ResolverUpdated(address indexed oldResolver, address indexed newResolver);

    constructor(address initialOwner, address initialResolver) {
        if (initialOwner == address(0)) revert InvalidAddress(ADDR_INITIAL_OWNER, initialOwner);
        if (initialResolver == address(0)) revert InvalidAddress(ADDR_INITIAL_RESOLVER, initialResolver);
        resolver = initialResolver;
        // Grant DEFAULT_ADMIN_ROLE to initialOwner so roles can be granted later
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    function setResolver(address newResolver) external onlyRole(ROLE_TIMELOCK) {
        if (newResolver == address(0)) revert InvalidAddress(ADDR_INITIAL_RESOLVER, newResolver);
        address oldResolver = resolver;
        resolver = newResolver;
        emit ResolverUpdated(oldResolver, newResolver);
    }

    /**
     * @notice Check if address is authorized dispute resolver
     * @dev In default implementation, checks against stored resolver
     */
    function isAuthorizedDisputeResolver(
        uint256 /* workflowId */,
        address checkDisputeResolver,
        bytes calldata /* escrowData */
    ) external view override returns (bool authorized, uint8 role) {
        // Check if the dispute resolver matches the stored resolver
        authorized = (checkDisputeResolver == resolver);
        role = 0;
        return (authorized, role);
    }

    /**
     * @notice Get dispute resolver for dispute
     */
    function getDisputeResolver(
        uint256 /* workflowId */,
        bytes calldata /* escrowData */
    ) external view override returns (address disputeResolver, uint8 escalationLevel) {
        return (resolver, 0);
    }

    /**
     * @notice Check if escalation is allowed (default: no escalation)
     */
    function canEscalate(
        uint256 /* workflowId */,
        uint8 /* currentLevel */,
        bytes calldata /* escrowData */
    ) external pure override returns (bool allowed, address nextResolver, uint256 escalationFee) {
        return (false, address(0), 0);
    }

    /**
     * @notice Execute escalation (default: not supported)
     */
    function executeEscalation(
        uint256 /* workflowId */,
        bytes calldata /* escrowData */
    ) external pure override returns (bool success, address newResolver, uint8 newLevel) {
        return (false, address(0), 0);
    }

    /**
     * @notice Get required appeal bond for escalation (DR v2)
     * @dev Default implementation: no bonds required (returns 0)
     */
    function getRequiredAppealBond(
        uint256 /* workflowId */,
        uint8 /* currentLevel */,
        bytes calldata /* escrowData */
    ) external pure override returns (uint256 amount, address token) {
        return (0, address(0));
    }

    /**
     * @notice Get incentive module address (optional interface)
     * @return module Address of incentive module (0 for default)
     * @dev Implemented to avoid "function selector not recognized" reverts in traces
     *      when probed by ModuleSnapshotLibrary.
     */
    function incentiveModule() external pure returns (address) {
        return address(0);
    }

    /**
     * @notice Get module name
     */
    function moduleName() external pure override returns (string memory) {
        return 'DefaultSingleResolver';
    }

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning)
     */
    function moduleVersion() external pure override returns (string memory version) {
        return '1.0.0';
    }

    /**
     * @notice Check if contract supports an interface
     * @param interfaceId The interface identifier
     * @return supported True if interface is supported
     * @dev AccessControl already includes ERC165
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControl, IERC165) returns (bool) {
        return
            interfaceId == type(IResolutionModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
