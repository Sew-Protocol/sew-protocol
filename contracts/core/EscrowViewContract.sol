// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './BaseEscrow.sol';
import '../types/EscrowTypes.sol';

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
        EscrowTransfer memory et = escrowContract.getEscrowTransfer(workflowId);
        summary = EscrowSummary({
            state: et.escrowState,
            token: et.token,
            from: et.from,
            to: et.to,
            amountAfterFee: et.amountAfterFee,
            resolver: et.disputeResolver,
            autoReleaseTime: et.autoReleaseTime,
            autoCancelTime: et.autoCancelTime
        });
    }

    /**
     * @notice Get escrow settings for an escrow
     * @param workflowId The escrow ID
     * @return settings Escrow settings
     */
    function getEscrowSettings(uint256 workflowId) external view returns (EscrowSettings memory) {
        return escrowContract.getEscrowSettings(workflowId);
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
        EscrowTransfer memory et = escrowContract.getEscrowTransfer(workflowId);
        status = et.escrowState;
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
        EscrowTransfer memory et = escrowContract.getEscrowTransfer(workflowId);
        return (et.from, et.to);
    }

    /**
     * @notice Get module snapshot for an escrow
     * @param workflowId The escrow ID
     * @return snapshot Module snapshot containing all module addresses and fees at time of escrow creation
     * @dev Note: moduleSnapshots is internal in BaseEscrow, so this function cannot access it directly.
     *      Consider exposing moduleSnapshots as public mapping or adding a minimal getter in BaseEscrow.
     */
    function getModuleSnapshot(uint256 workflowId) external view returns (BaseEscrow.ModuleSnapshot memory) {
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
        EscrowTransfer memory et = escrowContract.getEscrowTransfer(workflowId);
        return et.amountAfterFee;
    }

    /**
     * @notice Get total number of escrows created
     * @return Total count of escrows
     */
    function getEscrowCount() external view returns (uint256) {
        // escrowTransfers is a public array in BaseEscrow
        // Access via public getter: escrowTransfers.length
        // Note: Solidity generates a public getter for public arrays, but .length is not directly accessible
        // We need to use a workaround or add a minimal getter in BaseEscrow
        revert('EscrowCount accessor removed - use events to track escrow count');
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
    ) external view returns (bool exists, bool isRelease, uint256 appealDeadline, bytes32 resolutionHash) {
        // pendingSettlements is a public mapping in BaseEscrow
        // Access via public getter: pendingSettlements(workflowId)
        // Note: Solidity generates a public getter for public mappings
        (exists, isRelease, appealDeadline, resolutionHash) = escrowContract.pendingSettlements(workflowId);
    }

    /**
     * @notice Get timeout configuration
     * @return config Timeout configuration
     */
    function getTimeoutConfig() external view returns (TimeoutConfig memory) {
        return escrowContract.getTimeoutConfig();
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
        EscrowTransfer memory et = escrowContract.getEscrowTransfer(workflowId);
        TimeoutConfig memory config = escrowContract.getTimeoutConfig();
        (bool timedOut, uint256 remaining) = DisputeManagementLibrary.isTimedOut(
            workflowId,
            et.escrowState,
            escrowContract.disputeRaisedTimestamp(workflowId),
            config.maxDisputeDuration
        );
        return (timedOut, remaining);
    }
}
