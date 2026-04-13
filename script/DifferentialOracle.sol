// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../contracts/core/EscrowVault.sol';
import '../contracts/types/EscrowTypes.sol';
import '../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';

/**
 * @title DifferentialOracle
 * @notice Thin read-only adapter for the differential testing harness.
 *
 * Exposes individual flat getters so `cast call` returns single scalar values
 * that Python can parse without struct decoding.
 *
 * Deployed once per Anvil session alongside the EscrowVault + DR module stack.
 * Never used in production — test-only helper.
 *
 * EscrowTransfer tuple field order (from EscrowTypes.sol):
 *   0  address token
 *   1  address to
 *   2  address from
 *   3  address disputeResolver
 *   4  uint256 amountAfterFee
 *   5  uint64  autoReleaseTime
 *   6  uint64  autoCancelTime
 *   7  EscrowState escrowState
 *   8  SenderStatus senderStatus
 *   9  RecipientStatus recipientStatus
 *
 * BaseEscrow.PendingSettlement tuple field order:
 *   0  bool    exists
 *   1  bool    isRelease
 *   2  uint256 appealDeadline
 *   3  bytes32 resolutionHash
 */
contract DifferentialOracle {
    EscrowVault public immutable vault;
    DecentralizedResolutionModule public immutable drModule;

    constructor(address _vault, address _drModule) {
        vault = EscrowVault(_vault);
        drModule = DecentralizedResolutionModule(_drModule);
    }

    /// @notice EscrowState enum value for a workflow (0=NONE … 5=RESOLVED)
    function escrowState(uint256 wfId) external view returns (uint8) {
        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(wfId);
        return uint8(state);
    }

    /// @notice Amount after fee still held in escrow for a workflow
    function escrowAmount(uint256 wfId) external view returns (uint256) {
        (,,,, uint256 amount,,,,,) = vault.escrowTransfers(wfId);
        return amount;
    }

    /// @notice Whether a pending settlement record exists
    function pendingExists(uint256 wfId) external view returns (bool) {
        (bool exists,,,) = vault.pendingSettlements(wfId);
        return exists;
    }

    /// @notice Whether a pending settlement is a release (vs cancel)
    function pendingIsRelease(uint256 wfId) external view returns (bool) {
        (, bool isRelease,,) = vault.pendingSettlements(wfId);
        return isRelease;
    }

    /// @notice Current dispute round for a workflow (0=L0, 1=L1, 2=external)
    function disputeLevel(uint256 wfId) external view returns (uint8) {
        (, uint8 round,) = drModule.getAppealDeadlineAndRound(wfId, address(vault));
        return round;
    }

    /// @notice Principal held in escrow for a token
    function principalHeld(address token) external view returns (uint256) {
        (uint256 principal,,,) = vault.getAccountingBreakdown(token);
        return principal;
    }

    /// @notice Fees collected for a token
    function feesCollected(address token) external view returns (uint256) {
        (, uint256 fees,,) = vault.getAccountingBreakdown(token);
        return fees;
    }

    /// @notice Current block timestamp (matches model :block-time)
    function blockTime() external view returns (uint256) {
        return block.timestamp;
    }
}
