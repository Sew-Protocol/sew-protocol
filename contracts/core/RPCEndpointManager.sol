// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title RPCEndpointManager
 * @notice Manages RPC endpoints and failover configuration for multi-L2
 * @dev Stores endpoint URLs off-chain via events, on-chain stores metadata
 *
 * ## Purpose
 *
 * This contract manages RPC endpoint configuration for multi-L2 support:
 *
 * 1. **Primary + Backup Endpoints**: Each chain has primary and backup
 * 2. **Health Status**: Track which endpoints are working
 * 3. **Fallback Logic**: Automatically use backup if primary fails
 * 4. **Rate Limiting**: Optional rate limit per endpoint
 * 5. **History**: Audit trail of configuration changes
 *
 * ## Architecture
 *
 * ```
 * ChainID → [Primary Endpoint, Backup Endpoint]
 *           ↓
 *           Health Status → (working, lastCheck, failureCount)
 *           ↓
 *           Use Primary if working, else use Backup
 * ```
 */
contract RPCEndpointManager {
    // Chain IDs
    uint256 public constant ETHEREUM = 1;
    uint256 public constant BASE = 8453;
    uint256 public constant ARBITRUM = 42161;
    uint256 public constant OPTIMISM = 10;

    /// @notice RPC endpoint configuration
    struct RPCEndpoint {
        string endpoint; // URL stored off-chain via event
        bool active;
        uint64 registeredAt;
        uint256 rateLimit; // requests per minute (0 = unlimited)
    }

    /// @notice Endpoint health status
    struct HealthStatus {
        bool working;
        uint64 lastCheck;
        uint256 failureCount;
        uint256 successCount;
    }

    /// @notice Primary and backup endpoints per chain
    mapping(uint256 => RPCEndpoint) public primaryEndpoints;
    mapping(uint256 => RPCEndpoint) public backupEndpoints;

    /// @notice Health status tracking
    mapping(uint256 => HealthStatus) public endpointHealth;

    /// @notice Authorized managers
    mapping(address => bool) public isManager;
    uint256 public managerCount;

    // Events
    event PrimaryEndpointConfigured(
        uint256 indexed chainId,
        string endpoint,
        uint256 rateLimit,
        uint64 timestamp
    );
    event BackupEndpointConfigured(
        uint256 indexed chainId,
        string endpoint,
        uint256 rateLimit,
        uint64 timestamp
    );
    event EndpointHealthUpdated(
        uint256 indexed chainId,
        bool working,
        uint256 failureCount,
        uint256 successCount
    );
    event ManagerAdded(address indexed manager);
    event ManagerRemoved(address indexed manager);
    event RateLimitUpdated(uint256 indexed chainId, uint256 newLimit);

    // Errors
    error NotManager(address caller);
    error EndpointAlreadyConfigured(uint256 chainId);
    error InvalidRateLimit(uint256 limit);

    modifier onlyManager() {
        if (!isManager[msg.sender]) revert NotManager(msg.sender);
        _;
    }

    constructor(address[] memory initialManagers) {
        require(initialManagers.length > 0, 'NoManagers');

        for (uint256 i = 0; i < initialManagers.length; i++) {
            require(initialManagers[i] != address(0), 'ZeroManager');
            isManager[initialManagers[i]] = true;
            emit ManagerAdded(initialManagers[i]);
        }

        managerCount = initialManagers.length;
    }

    /// @notice Configure primary endpoint for a chain
    function setPrimaryEndpoint(
        uint256 chainId,
        string calldata endpoint,
        uint256 rateLimit
    ) external onlyManager {
        require(bytes(endpoint).length > 0, 'EmptyEndpoint');
        require(rateLimit <= 10000, 'RateLimitTooHigh'); // Max 10k req/min

        primaryEndpoints[chainId] = RPCEndpoint({
            endpoint: endpoint,
            active: true,
            registeredAt: uint64(block.timestamp),
            rateLimit: rateLimit
        });

        endpointHealth[chainId] = HealthStatus({
            working: true,
            lastCheck: uint64(block.timestamp),
            failureCount: 0,
            successCount: 1
        });

        emit PrimaryEndpointConfigured(chainId, endpoint, rateLimit, uint64(block.timestamp));
    }

    /// @notice Configure backup endpoint for a chain
    function setBackupEndpoint(
        uint256 chainId,
        string calldata endpoint,
        uint256 rateLimit
    ) external onlyManager {
        require(bytes(endpoint).length > 0, 'EmptyEndpoint');
        require(rateLimit <= 10000, 'RateLimitTooHigh');

        backupEndpoints[chainId] = RPCEndpoint({
            endpoint: endpoint,
            active: true,
            registeredAt: uint64(block.timestamp),
            rateLimit: rateLimit
        });

        emit BackupEndpointConfigured(chainId, endpoint, rateLimit, uint64(block.timestamp));
    }

    /// @notice Update endpoint health status
    function recordSuccess(uint256 chainId) external onlyManager {
        HealthStatus storage health = endpointHealth[chainId];
        health.working = true;
        health.lastCheck = uint64(block.timestamp);
        health.successCount++;
        if (health.failureCount > 0) health.failureCount--; // Reset on success

        emit EndpointHealthUpdated(chainId, true, health.failureCount, health.successCount);
    }

    /// @notice Record endpoint failure
    function recordFailure(uint256 chainId) external onlyManager {
        HealthStatus storage health = endpointHealth[chainId];
        health.lastCheck = uint64(block.timestamp);
        health.failureCount++;

        // Mark as unhealthy after 3 failures
        if (health.failureCount >= 3) {
            health.working = false;
        }

        emit EndpointHealthUpdated(chainId, health.working, health.failureCount, health.successCount);
    }

    /// @notice Reset health status (manual recovery)
    function resetHealth(uint256 chainId) external onlyManager {
        HealthStatus storage health = endpointHealth[chainId];
        health.working = true;
        health.failureCount = 0;
        health.lastCheck = uint64(block.timestamp);

        emit EndpointHealthUpdated(chainId, true, 0, health.successCount);
    }

    /// @notice Get active endpoint for a chain (primary if working, else backup)
    function getActiveEndpoint(uint256 chainId) external view returns (string memory endpoint, bool isPrimary) {
        HealthStatus memory health = endpointHealth[chainId];

        if (health.working && primaryEndpoints[chainId].active) {
            return (primaryEndpoints[chainId].endpoint, true);
        } else if (backupEndpoints[chainId].active) {
            return (backupEndpoints[chainId].endpoint, false);
        }

        revert('NoActiveEndpoint');
    }

    /// @notice Check if endpoint is healthy
    function isHealthy(uint256 chainId) external view returns (bool) {
        return endpointHealth[chainId].working;
    }

    /// @notice Get health status details
    function getHealthStatus(uint256 chainId)
        external
        view
        returns (bool working, uint256 failureCount, uint256 successCount, uint64 lastCheck)
    {
        HealthStatus memory health = endpointHealth[chainId];
        return (health.working, health.failureCount, health.successCount, health.lastCheck);
    }

    /// @notice Update rate limit for primary endpoint
    function updatePrimaryRateLimit(uint256 chainId, uint256 newLimit) external onlyManager {
        require(newLimit <= 10000, 'RateLimitTooHigh');
        primaryEndpoints[chainId].rateLimit = newLimit;
        emit RateLimitUpdated(chainId, newLimit);
    }

    /// @notice Update rate limit for backup endpoint
    function updateBackupRateLimit(uint256 chainId, uint256 newLimit) external onlyManager {
        require(newLimit <= 10000, 'RateLimitTooHigh');
        backupEndpoints[chainId].rateLimit = newLimit;
        emit RateLimitUpdated(chainId, newLimit);
    }

    /// @notice Disable an endpoint temporarily
    function disableEndpoint(uint256 chainId, bool isPrimary) external onlyManager {
        if (isPrimary) {
            primaryEndpoints[chainId].active = false;
        } else {
            backupEndpoints[chainId].active = false;
        }
    }

    /// @notice Re-enable an endpoint
    function enableEndpoint(uint256 chainId, bool isPrimary) external onlyManager {
        if (isPrimary) {
            primaryEndpoints[chainId].active = true;
        } else {
            backupEndpoints[chainId].active = true;
        }
    }

    /// @notice Add a manager
    function addManager(address manager) external onlyManager {
        require(manager != address(0), 'ZeroManager');
        require(!isManager[manager], 'AlreadyManager');

        isManager[manager] = true;
        managerCount++;

        emit ManagerAdded(manager);
    }

    /// @notice Remove a manager
    function removeManager(address manager) external onlyManager {
        require(isManager[manager], 'NotManager');
        require(managerCount > 1, 'CannotRemoveLastManager');

        isManager[manager] = false;
        managerCount--;

        emit ManagerRemoved(manager);
    }
}
