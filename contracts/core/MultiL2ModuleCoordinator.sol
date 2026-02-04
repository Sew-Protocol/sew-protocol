// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title MultiL2ModuleCoordinator
 * @notice Coordinates module activation across multiple L2s
 * @dev Enables synchronized updates of escrow modules on all chains
 *
 * ## Purpose
 *
 * This contract coordinates module updates across L2s:
 *
 * 1. **Synchronized Updates**: All L2s activate modules at same time
 * 2. **Staged Deployment**: Queue → Delay → Activate workflow
 * 3. **Coordination**: Track activation status per chain
 * 4. **Recovery**: Rollback if some chains fail
 * 5. **Audit Trail**: History of all updates
 *
 * ## Workflow
 *
 * ```
 * Stage 1: Queue
 * └─ Governance proposes module swap
 *
 * Stage 2: Voting
 * └─ DAO votes on activation
 *
 * Stage 3: Delay (48h)
 * └─ Security delay for review
 *
 * Stage 4: Activate on L2s
 * └─ Keepers activate on each L2
 *
 * Stage 5: Verify
 * └─ Check all L2s activated
 * ```
 */
contract MultiL2ModuleCoordinator {
    // Chain IDs
    uint256 public constant ETHEREUM = 1;
    uint256 public constant BASE = 8453;
    uint256 public constant ARBITRUM = 42161;
    uint256 public constant OPTIMISM = 10;

    uint256[] public supportedChains = [ETHEREUM, BASE, ARBITRUM, OPTIMISM];

    /// @notice Module update coordination
    struct ModuleUpdate {
        bytes32 updateId;
        address module;
        bytes4 moduleType; // e.g., "yield", "resolution", etc.
        uint64 queuedAt;
        uint64 activateAfter;
        uint256 chainsMask; // Bitmask of chains requiring activation
        uint256 activatedChainsMask; // Bitmask of chains that activated
        bool completed;
        string description;
    }

    /// @notice Tracking per-chain activation
    struct ChainActivationStatus {
        bool activated;
        uint64 activatedAt;
        bytes32 txHash; // Transaction hash on L2
        string statusMessage;
    }

    /// @notice Module update storage
    mapping(bytes32 => ModuleUpdate) public moduleUpdates;
    bytes32[] public updateIds;

    /// @notice Activation status per update/chain
    mapping(bytes32 => mapping(uint256 => ChainActivationStatus)) public activationStatus;

    /// @notice Authorized updaters (governance, timelock)
    mapping(address => bool) public isAuthorized;
    uint256 public authorizedCount;

    // Configuration
    uint64 public constant MIN_ACTIVATION_DELAY = 48 hours;

    // Events
    event ModuleUpdateQueued(
        bytes32 indexed updateId,
        address indexed module,
        bytes4 moduleType,
        uint64 queuedAt,
        uint64 activateAfter,
        string description
    );
    event ChainActivationStarted(bytes32 indexed updateId, uint256 indexed chainId);
    event ChainActivationCompleted(
        bytes32 indexed updateId,
        uint256 indexed chainId,
        bytes32 txHash,
        uint64 activatedAt
    );
    event ChainActivationFailed(bytes32 indexed updateId, uint256 indexed chainId, string reason);
    event ModuleUpdateCompleted(bytes32 indexed updateId, uint256 activatedChainCount);
    event AuthorizerAdded(address indexed account);
    event AuthorizerRemoved(address indexed account);

    // Errors
    error NotAuthorized(address caller);
    error InvalidModule(address module);
    error UpdateNotFound(bytes32 updateId);
    error UpdateNotReady(bytes32 updateId, uint64 availableAt);
    error ChainNotSupported(uint256 chainId);
    error AlreadyActivated(bytes32 updateId, uint256 chainId);
    error DelayNotMet(bytes32 updateId);

    modifier onlyAuthorized() {
        if (!isAuthorized[msg.sender]) revert NotAuthorized(msg.sender);
        _;
    }

    constructor(address[] memory initialAuthorizers) {
        require(initialAuthorizers.length > 0, 'NoAuthorizers');

        for (uint256 i = 0; i < initialAuthorizers.length; i++) {
            require(initialAuthorizers[i] != address(0), 'ZeroAuthorizer');
            isAuthorized[initialAuthorizers[i]] = true;
            emit AuthorizerAdded(initialAuthorizers[i]);
        }

        authorizedCount = initialAuthorizers.length;
    }

    /// @notice Queue a module update for all supported L2s
    function queueModuleUpdate(
        address module,
        bytes4 moduleType,
        string calldata description
    ) external onlyAuthorized returns (bytes32 updateId) {
        require(module != address(0), 'InvalidModule');

        updateId = keccak256(
            abi.encodePacked(module, moduleType, block.timestamp, msg.sender)
        );

        uint64 queuedAt = uint64(block.timestamp);
        uint64 activateAfter = queuedAt + MIN_ACTIVATION_DELAY;

        // Create bitmask for all supported chains
        uint256 chainsMask = 0;
        for (uint256 i = 0; i < supportedChains.length; i++) {
            chainsMask |= (1 << i);
        }

        ModuleUpdate storage update = moduleUpdates[updateId];
        update.updateId = updateId;
        update.module = module;
        update.moduleType = moduleType;
        update.queuedAt = queuedAt;
        update.activateAfter = activateAfter;
        update.chainsMask = chainsMask;
        update.activatedChainsMask = 0;
        update.completed = false;
        update.description = description;

        updateIds.push(updateId);

        emit ModuleUpdateQueued(updateId, module, moduleType, queuedAt, activateAfter, description);
    }

    /// @notice Record activation on a specific chain
    function recordActivation(
        bytes32 updateId,
        uint256 chainId,
        bytes32 txHash,
        string calldata statusMessage
    ) external onlyAuthorized {
        ModuleUpdate storage update = moduleUpdates[updateId];
        if (update.module == address(0)) revert UpdateNotFound(updateId);
        if (block.timestamp < update.activateAfter) {
            revert UpdateNotReady(updateId, update.activateAfter);
        }

        // Verify chain is supported
        bool chainSupported = false;
        uint256 chainIndex = 0;
        for (uint256 i = 0; i < supportedChains.length; i++) {
            if (supportedChains[i] == chainId) {
                chainSupported = true;
                chainIndex = i;
                break;
            }
        }
        if (!chainSupported) revert ChainNotSupported(chainId);

        ChainActivationStatus storage status = activationStatus[updateId][chainId];
        if (status.activated) revert AlreadyActivated(updateId, chainId);

        // Mark chain as activated
        status.activated = true;
        status.activatedAt = uint64(block.timestamp);
        status.txHash = txHash;
        status.statusMessage = statusMessage;

        // Update bitmask
        update.activatedChainsMask |= (1 << chainIndex);

        emit ChainActivationCompleted(updateId, chainId, txHash, uint64(block.timestamp));

        // Check if all chains activated
        if (update.activatedChainsMask == update.chainsMask) {
            update.completed = true;
            emit ModuleUpdateCompleted(updateId, supportedChains.length);
        }
    }

    /// @notice Record failed activation on a chain
    function recordActivationFailure(
        bytes32 updateId,
        uint256 chainId,
        string calldata reason
    ) external onlyAuthorized {
        ModuleUpdate storage update = moduleUpdates[updateId];
        if (update.module == address(0)) revert UpdateNotFound(updateId);

        ChainActivationStatus storage status = activationStatus[updateId][chainId];
        status.statusMessage = reason;

        emit ChainActivationFailed(updateId, chainId, reason);
    }

    /// @notice Get activation status for an update
    function getActivationStatus(bytes32 updateId)
        external
        view
        returns (
            bool completed,
            uint256 activatedChainCount,
            uint256 totalChains,
            ModuleUpdate memory update
        )
    {
        ModuleUpdate storage moduleUpdate = moduleUpdates[updateId];
        if (moduleUpdate.module == address(0)) revert UpdateNotFound(updateId);

        update = moduleUpdate;
        totalChains = supportedChains.length;
        activatedChainCount = _countBits(moduleUpdate.activatedChainsMask);
        completed = moduleUpdate.completed;
    }

    /// @notice Get status for specific chain
    function getChainStatus(bytes32 updateId, uint256 chainId)
        external
        view
        returns (ChainActivationStatus memory)
    {
        return activationStatus[updateId][chainId];
    }

    /// @notice Check if activation is ready
    function isReady(bytes32 updateId) external view returns (bool ready, uint64 readyAt) {
        ModuleUpdate storage update = moduleUpdates[updateId];
        if (update.module == address(0)) revert UpdateNotFound(updateId);

        ready = block.timestamp >= update.activateAfter;
        readyAt = update.activateAfter;
    }

    /// @notice Get all supported chains
    function getSupportedChains() external view returns (uint256[] memory) {
        return supportedChains;
    }

    /// @notice Get list of pending updates
    function getPendingUpdates() external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < updateIds.length; i++) {
            if (!moduleUpdates[updateIds[i]].completed) {
                count++;
            }
        }

        bytes32[] memory pending = new bytes32[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < updateIds.length; i++) {
            if (!moduleUpdates[updateIds[i]].completed) {
                pending[idx] = updateIds[i];
                idx++;
            }
        }

        return pending;
    }

    /// @notice Add authorized address
    function addAuthorizer(address account) external onlyAuthorized {
        require(account != address(0), 'ZeroAuthorizer');
        require(!isAuthorized[account], 'AlreadyAuthorized');

        isAuthorized[account] = true;
        authorizedCount++;

        emit AuthorizerAdded(account);
    }

    /// @notice Remove authorized address
    function removeAuthorizer(address account) external onlyAuthorized {
        require(isAuthorized[account], 'NotAuthorized');
        require(authorizedCount > 1, 'CannotRemoveLastAuthorizer');

        isAuthorized[account] = false;
        authorizedCount--;

        emit AuthorizerRemoved(account);
    }

    /// @notice Helper: count set bits in bitmask
    function _countBits(uint256 mask) internal pure returns (uint256 count) {
        while (mask > 0) {
            count += mask & 1;
            mask >>= 1;
        }
    }
}
