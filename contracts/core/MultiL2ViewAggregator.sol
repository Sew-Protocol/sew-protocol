// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './BaseEscrow.sol';
import './EscrowVault.sol';
import '../types/EscrowTypes.sol';

/**
 * @title MultiL2ViewAggregator
 * @notice Optimized view contract for multicall-friendly batch reads across L2s
 * @dev Designed for 3Commas Multicall and similar batch query tools
 *
 * ## Purpose
 *
 * This contract provides standardized, multicall-compatible view functions
 * that can be batched efficiently across multiple L2s with a single RPC call.
 *
 * All functions follow consistent patterns:
 * - No parameters (except IDs for specific queries)
 * - Return fixed-size structs or arrays
 * - No loops or complex computation
 * - Safe for batch queries with gas limits
 *
 * ## Multicall Usage Example
 *
 * ```typescript
 * const multicall = new ethers.Contract(MULTICALL3_ADDRESS, Multicall3ABI);
 * const aggregator = new ethers.Contract(AGGREGATOR_ADDRESS, AggregatorABI);
 *
 * const calls = [
 *   {
 *     target: ETHEREUM_AGGREGATOR,
 *     callData: aggregator.interface.encodeFunctionData('getEscrowSummary', [escrowId])
 *   },
 *   {
 *     target: BASE_AGGREGATOR,
 *     callData: aggregator.interface.encodeFunctionData('getEscrowSummary', [escrowId])
 *   },
 *   {
 *     target: ARBITRUM_AGGREGATOR,
 *     callData: aggregator.interface.encodeFunctionData('getEscrowSummary', [escrowId])
 *   }
 * ];
 *
 * const results = await multicall.aggregate3(calls);
 * // All 3 L2s queried in 1 RPC call!
 * ```
 *
 * ## Design Principles
 *
 * 1. **Fixed-Size Structs**: All return types have known size for efficient batching
 * 2. **Consistent Naming**: All view functions follow pattern: get{Entity}{Detail}
 * 3. **No Loops**: Avoid enumeration; use specific queries by ID
 * 4. **Safe Bounds**: All functions safe against out-of-bounds access
 * 5. **Cross-L2 Identical**: Same bytecode generates same behavior on all L2s
 */
contract MultiL2ViewAggregator {
    EscrowVault public immutable vault;

    error InvalidWorkflowId(uint256 workflowId, uint256 maxWorkflowId);

    /**
     * @notice Compact view of escrow state for multicall queries
     * @dev Fixed-size struct for efficient batching (fits in 2-3 words)
     */
    struct EscrowSnapshot {
        address token;
        address from;
        address to;
        address resolver;
        uint256 amount;
        uint64 autoReleaseTime;
        uint64 autoCancelTime;
        uint8 state; // EscrowState as uint8
    }

    /**
     * @notice Compact view of escrow settings for multicall queries
     * @dev Fixed-size struct for efficient batching
     */
    struct SettingsSnapshot {
        address customResolver;
        uint8 yieldPreset;
        uint256 autoReleaseTime;
        uint256 autoCancelTime;
    }

    /**
     * @notice Balances view for a user across multiple tokens
     * @dev Used for L2 balance aggregation
     */
    struct BalanceSnapshot {
        address token;
        uint256 escrowedBalance;
        uint256 claimableBalance;
        uint256 heldInEscrow;
    }

    constructor(address _vault) {
        require(_vault != address(0), 'ZeroVaultAddress');
        vault = EscrowVault(_vault);
    }

    /**
     * @notice Get escrow state snapshot - optimized for multicall
     * @param workflowId Escrow ID to query
     * @return snapshot Compact escrow state
     */
    function getEscrowSnapshot(uint256 workflowId) external view returns (EscrowSnapshot memory snapshot) {
        uint256 escrowCount = vault.getEscrowCount();
        if (workflowId >= escrowCount) {
            revert InvalidWorkflowId(workflowId, escrowCount);
        }

        (
            address token,
            address to,
            address from,
            address disputeResolver,
            uint256 amountAfterFee,
            uint64 autoReleaseTime,
            uint64 autoCancelTime,
            EscrowState escrowState,
            ,
        ) = vault.escrowTransfers(workflowId);

        snapshot = EscrowSnapshot({
            token: token,
            from: from,
            to: to,
            resolver: disputeResolver,
            amount: amountAfterFee,
            autoReleaseTime: autoReleaseTime,
            autoCancelTime: autoCancelTime,
            state: uint8(escrowState)
        });
    }

    /**
     * @notice Get escrow settings snapshot - optimized for multicall
     * @param workflowId Escrow ID to query
     * @return snapshot Compact escrow settings
     */
    function getSettingsSnapshot(uint256 workflowId) external view returns (SettingsSnapshot memory snapshot) {
        uint256 escrowCount = vault.getEscrowCount();
        if (workflowId >= escrowCount) {
            revert InvalidWorkflowId(workflowId, escrowCount);
        }

        (
            address customResolver,
            address releaseAddress,
            YieldPreset yieldPreset,
            uint256 autoReleaseTime,
            uint256 autoCancelTime
        ) = vault.escrowSettings(workflowId);

        snapshot = SettingsSnapshot({
            customResolver: customResolver,
            yieldPreset: uint8(yieldPreset),
            autoReleaseTime: autoReleaseTime,
            autoCancelTime: autoCancelTime
        });
    }

    /**
     * @notice Get total held balance per token - for system health check
     * @param token Token address to check
     * @return heldAmount Total amount held in escrow for token
     */
    function getTotalHeldPerToken(address token) external view returns (uint256 heldAmount) {
        heldAmount = vault.totalHeldInEscrowPerToken(token);
    }

    /**
     * @notice Get total fees collected per token
     * @param token Token address to check
     * @return feesAmount Total fees collected for token
     */
    function getTotalFeesPerToken(address token) external view returns (uint256 feesAmount) {
        feesAmount = vault.totalFeesPerToken(token);
    }

    /**
     * @notice Get count of active escrows - for pagination and health checks
     * @return count Total escrow count
     */
    function getEscrowCount() external view returns (uint256 count) {
        count = vault.getEscrowCount();
    }

    /**
     * @notice Batch query multiple escrow snapshots
     * @dev Reverts if any ID is invalid; caller should validate IDs first
     * @param workflowIds Array of escrow IDs (max 10 for single RPC call)
     * @return snapshots Array of escrow snapshots
     */
    function batchGetEscrowSnapshots(uint256[] calldata workflowIds)
        external
        view
        returns (EscrowSnapshot[] memory snapshots)
    {
        snapshots = new EscrowSnapshot[](workflowIds.length);
        for (uint256 i = 0; i < workflowIds.length; i++) {
            snapshots[i] = this.getEscrowSnapshot(workflowIds[i]);
        }
    }

    /**
     * @notice Batch query multiple settings snapshots
     * @param workflowIds Array of escrow IDs (max 10 for single RPC call)
     * @return snapshots Array of settings snapshots
     */
    function batchGetSettingsSnapshots(uint256[] calldata workflowIds)
        external
        view
        returns (SettingsSnapshot[] memory snapshots)
    {
        snapshots = new SettingsSnapshot[](workflowIds.length);
        for (uint256 i = 0; i < workflowIds.length; i++) {
            snapshots[i] = this.getSettingsSnapshot(workflowIds[i]);
        }
    }

    /**
     * @notice Health check for L2 node - verifies escrow system is responsive
     * @return healthy True if system is responsive
     * @return escrowCount Current escrow count
     * @return lastEscrowId Last valid escrow ID
     */
    function healthCheck() external view returns (bool healthy, uint256 escrowCount, uint256 lastEscrowId) {
        escrowCount = vault.getEscrowCount();
        healthy = escrowCount > 0;
        lastEscrowId = healthy ? escrowCount - 1 : 0;
    }
}
