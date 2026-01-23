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
            uint256 defaultAutoReleaseTime,
            uint256 defaultAutoCancelTime,
            uint256 maxDisputeDuration,
            uint256 appealWindowDuration
        ) = escrowContract.timeoutConfig();
        config = TimeoutConfig({
            defaultAutoReleaseTime: defaultAutoReleaseTime,
            defaultAutoCancelTime: defaultAutoCancelTime,
            maxDisputeDuration: maxDisputeDuration,
            appealWindowDuration: appealWindowDuration
        });
    }

    /**
     * @notice Check if a dispute has timed out
     * @param workflowId The escrow ID
     * @return isTimedOut Whether dispute exceeded maxDisputeDuration
     * @return timeRemaining Seconds remaining until timeout (0 if timed out)
     */
    function isDisputeTimedOut(
        uint256 workflowId
    ) external view returns (bool isTimedOut, uint256 timeRemaining) {
        // Check bounds to avoid revert on invalid workflowId
        if (workflowId >= escrowContract.getEscrowCount()) {
            return (false, 0);
        }
        // Public array getter returns tuple - extract escrowState
        (
            , , , , , , ,
            EscrowState escrowState,
            ,
        ) = escrowContract.escrowTransfers(workflowId);
        
        // Public struct getter returns tuple - extract maxDisputeDuration
        (
            , , uint256 maxDisputeDuration,
        ) = escrowContract.timeoutConfig();
        
        (bool timedOut, uint256 remaining) = DisputeManagementLibrary.isTimedOut(
            workflowId,
            escrowState,
            escrowContract.disputeRaisedTimestamp(workflowId),
            maxDisputeDuration
        );
        return (timedOut, remaining);
    }
}
