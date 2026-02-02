// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './BaseEscrow.sol';
import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../libraries/SettingsValidationLibrary.sol';
import '../libraries/DisputeManagementLibrary.sol';

/**
 * @title EscrowViewContract
 * @notice External view contract for frontend consumption
 * @dev PRIORITY 4: Extracted view getters from BaseEscrow to reduce contract size
 * 
 *      This contract reads BaseEscrow/EscrowVault via public storage/getters
 *      and repackages results for frontend consumption.
 *      
 *      Core contracts keep only essential on-chain getters:
 *      - escrowTransfers(uint256) (public array getter)
 *      - claimableBalances(workflowId, user) (if needed onchain)
 *      - getEscrowSummary(workflowId) - compact view with fixed-size fields
 */
contract EscrowViewContract {
    BaseEscrow public immutable escrowContract;

    /**
     * @notice Compact escrow summary (fixed-size fields only)
     */
    struct EscrowSummary {
        EscrowState state;
        address token;
        address from;
        address to;
        uint256 amountAfterFee;
        address resolver;
        uint256 autoReleaseTime;
        uint256 autoCancelTime;
    }

    constructor(address _escrowContract) {
        escrowContract = BaseEscrow(_escrowContract);
    }

    /**
     * @notice Get compact escrow summary
     * @param workflowId The escrow ID
     * @return summary Compact escrow summary
     */
    function getEscrowSummary(uint256 workflowId) external view returns (EscrowSummary memory summary) {
        // Check bounds to avoid revert on invalid workflowId
        if (workflowId >= escrowContract.getEscrowCount()) {
            return EscrowSummary({
                state: EscrowState.NONE,
                token: address(0),
                from: address(0),
                to: address(0),
                amountAfterFee: 0,
                resolver: address(0),
                autoReleaseTime: 0,
                autoCancelTime: 0
            });
        }
        // Public array getter returns tuple - unpack into struct
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
        ) = escrowContract.escrowTransfers(workflowId);
        summary = EscrowSummary({
            state: escrowState,
            token: token,
            from: from,
            to: to,
            amountAfterFee: amountAfterFee,
            resolver: disputeResolver,
            autoReleaseTime: uint256(autoReleaseTime),
            autoCancelTime: uint256(autoCancelTime)
        });
    }

    /**
     * @notice Get escrow settings for an escrow
     * @param workflowId The escrow ID
     * @return settings Escrow settings
     */
    function getEscrowSettings(uint256 workflowId) external view returns (EscrowSettings memory settings) {
        // Public mapping getter returns tuple - unpack into struct
        // Note: yieldPreset is stored as YieldPreset enum in storage, but public getter returns as uint8
        (
            address customResolver,
            YieldPreset yieldPreset,
            uint256 autoReleaseTime,
            uint256 autoCancelTime
        ) = escrowContract.escrowSettings(workflowId);
        settings = EscrowSettings({
            customResolver: customResolver,
            yieldPreset: yieldPreset,
            autoReleaseTime: autoReleaseTime,
            autoCancelTime: autoCancelTime
        });
    }

    /**
     * @notice Get escrow status information
     * @param workflowId The escrow ID
     * @return status Current escrow state
     * @return isActive Whether escrow is active (PENDING or DISPUTED)
     * @return isPending Whether escrow is pending
     */
    function getEscrowStatusInfo(
        uint256 workflowId
    ) external view returns (EscrowState status, bool isActive, bool isPending) {
        // Check bounds to avoid revert on invalid workflowId
        if (workflowId >= escrowContract.getEscrowCount()) {
            return (EscrowState.NONE, false, false);
        }
        // Public array getter returns tuple - extract only escrowState
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrowContract.escrowTransfers(workflowId);
        status = escrowState;
        isActive = (status == EscrowState.PENDING || status == EscrowState.DISPUTED);
        isPending = (status == EscrowState.PENDING);
    }

    /**
     * @notice Get escrow participant addresses
     * @param workflowId The escrow ID
     * @return from Sender address
     * @return to Recipient address
     */
    function getEscrowParticipants(
        uint256 workflowId
    ) external view returns (address from, address to) {
        // Check bounds to avoid revert on invalid workflowId
        if (workflowId >= escrowContract.getEscrowCount()) {
            return (address(0), address(0));
        }
        // Public array getter returns tuple - extract only from and to
        (
            , address toAddr, address fromAddr, , , , , , ,
        ) = escrowContract.escrowTransfers(workflowId);
        return (fromAddr, toAddr);
    }

    /**
     * @notice Get module snapshot for an escrow
     * @return snapshot Module snapshot containing all module addresses and fees at time of escrow creation
     * @dev Note: moduleSnapshots is internal in BaseEscrow, so this function cannot access it directly.
     *      Consider exposing moduleSnapshots as public mapping or adding a minimal getter in BaseEscrow.
     */
    function getModuleSnapshot(uint256) external pure returns (BaseEscrow.ModuleSnapshot memory) {
        // moduleSnapshots is internal in BaseEscrow, so we cannot access it directly
        // This requires BaseEscrow to expose moduleSnapshots as public or add a minimal getter
        revert('ModuleSnapshot accessor removed - use events emitted at escrow creation');
    }

    /**
     * @notice Get total amount deposited (after fee) for an escrow
     * @param workflowId The escrow ID
     * @return Total amount deposited after fee deduction
     */
    function getTotalDeposited(uint256 workflowId) external view returns (uint256) {
        // Check bounds to avoid revert on invalid workflowId
        if (workflowId >= escrowContract.getEscrowCount()) {
            return 0;
        }
        // Public array getter returns tuple - extract only amountAfterFee
        (
            , , , , uint256 amountAfterFee, , , , ,
        ) = escrowContract.escrowTransfers(workflowId);
        return amountAfterFee;
    }

    /**
     * @notice Get total number of escrows created
     * @return Total count of escrows
     */
    function getEscrowCount() external view returns (uint256) {
        return escrowContract.getEscrowCount();
    }

    /**
     * @notice Get default escrow settings
     * @return Default escrow settings (all zeros/defaults)
     */
    function getDefaultSettings() external pure returns (EscrowSettings memory) {
        return SettingsValidationLibrary.getDefaultSettings();
    }

    /**
     * @notice Get pending settlement information
     * @param workflowId The escrow ID
     * @return exists Whether pending settlement exists
     * @return isRelease True if pending release, false if pending cancel
     * @return appealDeadline Appeal deadline timestamp
     * @return resolutionHash Resolution hash
     */
    function getPendingSettlement(
        uint256 workflowId
    ) external view returns (bool exists, bool isRelease, uint256 appealDeadline, bytes32 resolutionHash, bool canExecute) {
        // Public mapping getter returns tuple - unpack into struct
        (
            bool exists_,
            bool isRelease_,
            uint256 appealDeadline_,
            bytes32 resolutionHash_
        ) = escrowContract.pendingSettlements(workflowId);
        exists = exists_;
        isRelease = isRelease_;
        appealDeadline = appealDeadline_;
        resolutionHash = resolutionHash_;
        canExecute = exists && block.timestamp >= appealDeadline;
    }

    /**
     * @notice Get timeout configuration
     * @return config Timeout configuration
     */
    function getTimeoutConfig() external view returns (TimeoutConfig memory config) {
        // Public struct getter returns tuple - unpack into struct
        (
            uint256 defaultAutoReleaseDelay,
            uint256 defaultAutoCancelDelay,
            uint256 maxDisputeDuration,
            uint256 appealWindowDuration
        ) = escrowContract.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseDelay: defaultAutoReleaseDelay,
            defaultAutoCancelDelay: defaultAutoCancelDelay,
            maxDisputeDuration: maxDisputeDuration,
            appealWindowDuration: appealWindowDuration
        });
    }

    /**
     * @notice Get escrow timeline and status information
     * @param workflowId The escrow ID
     * @return timeline Timeline struct with deadlines and status
     */
    function getEscrowTimeline(uint256 workflowId) external view returns (EscrowTimeline memory timeline) {
        if (workflowId >= escrowContract.getEscrowCount()) return timeline;

        (
            , , , , ,
            uint64 autoReleaseTime,
            uint64 autoCancelTime,
            EscrowState state,
            SenderStatus sStatus,
            RecipientStatus rStatus
        ) = escrowContract.escrowTransfers(workflowId);

        (
            bool exists,
            ,
            uint256 appealDeadline,
            
        ) = escrowContract.pendingSettlements(workflowId);

        timeline.status = _deriveStatus(state, autoReleaseTime, autoCancelTime, exists, appealDeadline, sStatus, rStatus);
        timeline.nextDeadline = _calculateNextDeadline(autoReleaseTime, autoCancelTime, appealDeadline, exists, state);
        timeline.finalDeadline = _calculateFinalDeadline(autoReleaseTime, autoCancelTime, appealDeadline, exists, state);
        timeline.urgency = _deriveUrgency(timeline.nextDeadline);
        timeline.userCanExecute = (timeline.status == ActionableStatus.TIME_CONDITION_MET || timeline.status == ActionableStatus.APPEAL_READY);
        
        // Note: createdAt is not currently stored in BaseEscrow, we could add it to EscrowTransfer if needed.
        // For now we leave it as 0.
    }

    /**
     * @notice Get all workflow IDs for a user with specific role
     * @param user The address to check
     * @param role The role to filter by (BUYER, SELLER, RESOLVER)
     * @param offset Pagination offset
     * @param limit Pagination limit
     * @return ids Array of workflow IDs
     */
    function getWorkflowsByRole(
        address user,
        UserRole role,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory ids) {
        uint256 total = escrowContract.getEscrowCount();
        if (offset >= total) return new uint256[](0);
        
        uint256[] memory temp = new uint256[](limit > total - offset ? total - offset : limit);
        uint256 count = 0;
        
        for (uint256 i = offset; i < total && count < limit; i++) {
            (address token, address to, address from, address resolver, , , , , ,) = escrowContract.escrowTransfers(i);
            bool matchRole = false;
            if (role == UserRole.BUYER && from == user) matchRole = true;
            else if (role == UserRole.SELLER && to == user) matchRole = true;
            else if (role == UserRole.RESOLVER && resolver == user) matchRole = true;
            
            if (matchRole) {
                temp[count] = i;
                count++;
            }
        }
        
        ids = new uint256[](count);
        for (uint256 j = 0; j < count; j++) {
            ids[j] = temp[j];
        }
    }

    /**
     * @notice Check if an escrow is ready for automated actions (Gelato checker helper)
     * @param workflowId The escrow ID
     * @return ok True if automateTimedActions(workflowId) would return true
     * @return actionType The type of action (1=Release, 2=Cancel, 3=Settle)
     * @return isRelease True if funds will be released, false if refunded
     * @return nextDeadline Timestamp of the next potential state change (for bot sleep logic)
     * @return actionableSince Timestamp when the current action became available (0 if not actionable)
     */
    function canAutomate(uint256 workflowId) external view returns (
        bool ok, 
        uint8 actionType, 
        bool isRelease,
        uint64 nextDeadline,
        uint64 actionableSince
    ) {
        if (workflowId >= escrowContract.getEscrowCount()) return (false, 0, false, 0, 0);
        
        // Get escrow data via tuple unpacking (public array getter)
        (
            address token,
            address to,
            address from,
            address disputeResolver,
            uint256 amountAfterFee,
            uint64 autoReleaseTime,
            uint64 autoCancelTime,
            EscrowState state,
            SenderStatus senderStatus,
            RecipientStatus recipientStatus
        ) = escrowContract.escrowTransfers(workflowId);

        // Map to memory struct for SettlementOps
        EscrowTransfer memory et = EscrowTransfer({
            token: token,
            to: to,
            from: from,
            disputeResolver: disputeResolver,
            amountAfterFee: amountAfterFee,
            autoReleaseTime: autoReleaseTime,
            autoCancelTime: autoCancelTime,
            escrowState: state,
            senderStatus: senderStatus,
            recipientStatus: recipientStatus
        });

        // Get pending settlement data
        (
            bool exists,
            bool isReleasePending,
            uint256 appealDeadline,
            bytes32 resolutionHash
        ) = escrowContract.pendingSettlements(workflowId);

        SettlementOps.SettlementPendingSettlement memory pending = SettlementOps.SettlementPendingSettlement({
            exists: exists,
            isRelease: isReleasePending,
            appealDeadline: appealDeadline,
            resolutionHash: resolutionHash
        });

        // Query settlement ops (made public previously)
        SettlementOps settlementOps = SettlementOps(address(escrowContract.settlementOps()));
        if (address(settlementOps) == address(0)) return (false, 0, false, 0, 0);

        (
            uint256 dar,
            uint256 dac,
            uint256 mdd,
            uint256 awd
        ) = escrowContract.timeoutConfig();

        (actionType, isRelease) = settlementOps.computeTimedActions(
            workflowId, 
            et, 
            pending, 
            TimeoutConfig(dar, dac, mdd, awd)
        );
        
        ok = (actionType > 0);
        nextDeadline = _calculateNextDeadline(autoReleaseTime, autoCancelTime, appealDeadline, exists, state);
        if (ok) actionableSince = nextDeadline;
    }

    /**
     * @notice Get real-time yield metrics for an escrow
     * @param workflowId The escrow ID
     * @return metrics YieldMetrics struct with live data
     */
    function getYieldMetrics(uint256 workflowId) external view returns (YieldMetrics memory metrics) {
        if (workflowId >= escrowContract.getEscrowCount()) return metrics;

        (address token, , , , uint256 principal, , , , ,) = escrowContract.escrowTransfers(workflowId);
        metrics.principal = principal;
        metrics.yieldToken = token;

        // Try to query current yield from the generation module
        (address genMod, , , , , ,) = escrowContract.moduleSnapshots(workflowId);
        if (genMod != address(0) && genMod.code.length > 0) {
            try IYieldGenerationModule(genMod).getPosition(workflowId, token, address(escrowContract)) returns (IYieldGenerationModule.YieldPosition memory pos) {
                if (pos.isActive) {
                    metrics.accruedInterest = pos.currentYield;
                }
            } catch {
                // Fallback for older modules that don't have getPosition
                try IYieldGenerationModule(genMod).calculateYield(workflowId, token, address(escrowContract)) returns (uint256 yield) {
                    metrics.accruedInterest = yield;
                } catch {}
            }
        }
    }

    /**
     * @notice Get consensus status for multi-party flows (e.g., agreed cancellation)
     * @param workflowId The escrow ID
     * @return status CollaborationStatus struct
     */
    function getConsensusStatus(uint256 workflowId) external view returns (CollaborationStatus memory status) {
        if (workflowId >= escrowContract.getEscrowCount()) return status;

        ( , , , , , , , , SenderStatus sStatus, RecipientStatus rStatus) = escrowContract.escrowTransfers(workflowId);
        status.senderAgreed = (sStatus == SenderStatus.AGREE_TO_CANCEL);
        status.recipientAgreed = (rStatus == RecipientStatus.AGREE_TO_CANCEL);
        status.canFinalize = status.senderAgreed && status.recipientAgreed;
    }

    /**
     * @notice Get contextual info about the assigned resolver
     * @param workflowId The escrow ID
     * @return context ResolverContext struct
     */
    function getResolverContext(uint256 workflowId) external view returns (ResolverContext memory context) {
        if (workflowId >= escrowContract.getEscrowCount()) return context;

        ( , , , address resolver, , , , , ,) = escrowContract.escrowTransfers(workflowId);
        context.resolver = resolver;
        context.isContract = resolver.code.length > 0;
        
        if (context.isContract) {
            // Check for IResolutionModule (standard module)
            try IERC165(resolver).supportsInterface(type(IResolutionModule).interfaceId) returns (bool supported) {
                if (supported) {
                    context.interfaceId = type(IResolutionModule).interfaceId;
                    try IResolutionModule(resolver).moduleName() returns (string memory name) {
                        context.label = name;
                    } catch {
                        context.label = "Resolution Module";
                    }
                }
            } catch {
                // Check for IResolver (legacy or EIP standard)
                try IERC165(resolver).supportsInterface(0xd47afa87) returns (bool supported) { // IResolver.resolve selector
                    if (supported) {
                        context.interfaceId = 0xd47afa87;
                        context.label = "Standard Resolver";
                    }
                } catch {}
            }
        } else {
            context.label = "Human Mediator (EOA)";
        }
    }

    /**
     * @notice Get aggregated escrow stats for a user (Portfolio view)
     * @param user The address to check
     * @return asBuyer Count of escrows where user is buyer
     * @return asSeller Count of escrows where user is seller
     * @return asResolver Count of escrows where user is resolver
     */
    function getUserEscrowStats(address user) external view returns (
        uint256 asBuyer, 
        uint256 asSeller, 
        uint256 asResolver
    ) {
        uint256 total = escrowContract.getEscrowCount();
        for (uint256 i = 0; i < total; i++) {
            ( , address to, address from, address resolver, , , , EscrowState state, , ) = escrowContract.escrowTransfers(i);
            if (state == EscrowState.RELEASED || state == EscrowState.REFUNDED || state == EscrowState.RESOLVED) continue;

            if (from == user) asBuyer++;
            else if (to == user) asSeller++;
            else if (resolver == user) asResolver++;
        }
    }

    function _deriveStatus(
        EscrowState state,
        uint64 autoRelease,
        uint64 autoCancel,
        bool pendingExists,
        uint256 appealDeadline,
        SenderStatus sStatus,
        RecipientStatus rStatus
    ) internal view returns (ActionableStatus) {
        if (state == EscrowState.RELEASED || state == EscrowState.REFUNDED || state == EscrowState.RESOLVED) {
            return ActionableStatus.FINALIZED;
        }
        if (state == EscrowState.DISPUTED) {
            if (pendingExists) {
                return block.timestamp >= appealDeadline ? ActionableStatus.APPEAL_READY : ActionableStatus.APPEAL_WINDOW;
            }
            return ActionableStatus.DISPUTED_WAITING;
        }
        if (state == EscrowState.PENDING) {
            // Check for agreed cancellation (Consensus)
            if (sStatus == SenderStatus.AGREE_TO_CANCEL || rStatus == RecipientStatus.AGREE_TO_CANCEL) {
                return ActionableStatus.AWAITING_CONSENSUS;
            }

            bool timeMet = (autoRelease > 0 && block.timestamp >= autoRelease) || (autoCancel > 0 && block.timestamp >= autoCancel);
            return timeMet ? ActionableStatus.TIME_CONDITION_MET : ActionableStatus.AWAITING_CONDITION;
        }
        return ActionableStatus.NONE;
    }

    function _calculateNextDeadline(
        uint64 autoRelease,
        uint64 autoCancel,
        uint256 appealDeadline,
        bool pendingExists,
        EscrowState state
    ) internal view returns (uint64) {
        if (state == EscrowState.PENDING) {
            if (autoRelease > 0 && autoCancel > 0) return autoRelease < autoCancel ? autoRelease : autoCancel;
            if (autoRelease > 0) return autoRelease;
            if (autoCancel > 0) return autoCancel;
        }
        if (state == EscrowState.DISPUTED && pendingExists) {
            return uint64(appealDeadline);
        }
        return 0;
    }

    function _calculateFinalDeadline(
        uint64 autoRelease,
        uint64 autoCancel,
        uint256 appealDeadline,
        bool pendingExists,
        EscrowState state
    ) internal view returns (uint64) {
        // Conservative estimate of when funds become irreversible
        if (state == EscrowState.PENDING) {
            // If auto-cancel triggers, funds are refunded (irreversible)
            // If auto-release triggers, funds are released (irreversible)
            return _calculateNextDeadline(autoRelease, autoCancel, appealDeadline, pendingExists, state);
        }
        if (state == EscrowState.DISPUTED && pendingExists) {
            return uint64(appealDeadline);
        }
        return 0;
    }

    function _deriveUrgency(uint64 deadline) internal view returns (UrgencyLevel) {
        if (deadline == 0 || deadline <= block.timestamp) return UrgencyLevel.NONE;
        uint256 diff;
        unchecked {
            if (deadline < block.timestamp) return UrgencyLevel.NONE;
            diff = uint256(deadline) - block.timestamp;
        }
        if (diff < 1 hours) return UrgencyLevel.CRITICAL;
        if (diff < 24 hours) return UrgencyLevel.HIGH;
        if (diff < 48 hours) return UrgencyLevel.MEDIUM;
        return UrgencyLevel.LOW;
    }
}
