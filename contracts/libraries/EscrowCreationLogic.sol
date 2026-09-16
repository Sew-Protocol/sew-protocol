// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../libraries/SettingsValidationLibrary.sol';
import '../libraries/YieldPresetLibrary.sol';
import '../libraries/EscrowEncodingLibrary.sol';
import '../shared/interfaces/IResolutionModule.sol';

/**
 * @title EscrowCreationLogic
 * @notice Compile-time escrow creation derivation, mirroring the externally
 *         deployed CreateOps contract.
 *
 * @dev Preserves the CreateOps separation of concerns:
 *      - derive only: returns a result (or reverts), never mutates escrow state
 *      - no callbacks, no escrow storage access
 *      - all inputs explicit, including the two policy flags that CreateOps owned
 *        as mutable state (`resolverMustBeContract`, `yieldDepositsPaused`) and
 *        the escrow address reported to the resolution module.
 *
 *      The escrow remains the sole authoritative mutator: it calls this function,
 *      then applies the derived result to escrow state. This keeps the
 *      derive -> result -> apply boundary.
 *
 *      NOTE: this library is not yet wired into production; it is introduced to
 *      establish differential equivalence against CreateOps before the runtime
 *      boundary is removed and policy ownership is decided.
 */
library EscrowCreationLogic {
    uint256 private constant ESCROW_FEE_DENOMINATOR = 10000;

    /// @dev Result of escrow creation computation (matches CreateOps.CreateResult).
    struct CreateResult {
        uint256 fee; // Escrow fee amount
        uint256 amountAfterFee; // Amount after fee deduction
        address resolver; // Default resolver address
        bool yieldEnabled; // Whether yield is enabled for this escrow
        bool shouldDepositYield; // Whether to attempt yield deposit
    }

    /**
     * @notice Compute escrow creation parameters.
     * @dev Compute-only: does not modify escrow state. Reverts identically to
     *      CreateOps for invalid inputs.
     * @param escrowContract Address reported to the resolution module (equivalent
     *        to CreateOps' `_msgSender()`, which is the calling escrow).
     * @param resolverMustBeContract Policy flag formerly owned by CreateOps.
     * @param yieldDepositsPaused Policy flag formerly owned by CreateOps.
     */
    function computeEscrowCreation(
        address token,
        address to,
        address from,
        uint256 amount,
        EscrowSettings memory settings,
        uint256 escrowFee,
        uint256 workflowId,
        address resolutionModule,
        address escrowContract,
        bool resolverMustBeContract,
        bool yieldDepositsPaused
    ) internal view returns (CreateResult memory result) {
        // Validate inputs
        if (token == address(0)) revert InvalidAddress(ADDR_TOKEN, token);
        if (amount == 0) revert AmountZero();
        SettingsValidationLibrary.validateEscrowAmount(amount);
        SettingsValidationLibrary.validateRecipient(to, from, settings.releaseAddress);

        // Use explicit validation time (always block.timestamp in production)
        uint256 validationTime = block.timestamp;
        SettingsValidationLibrary.validateEscrowSettings(settings, validationTime, resolverMustBeContract);

        // Fee calculation: fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR
        result.fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;
        result.amountAfterFee = amount - result.fee;

        // Resolver determination: Query resolution module for default resolver
        result.resolver = _getDisputeResolverForNewEscrow(
            resolutionModule,
            workflowId,
            token,
            from,
            to,
            result.amountAfterFee,
            escrowContract
        );

        // Yield configuration
        result.yieldEnabled = YieldPresetLibrary.isYieldEnabled(settings.yieldPreset);
        if (result.yieldEnabled && !yieldDepositsPaused) {
            // Validate preset parameters (sender and recipient addresses)
            YieldPresetLibrary.validatePresetParams(settings.yieldPreset, from, to);
            // Validate yield opt-in amount (graceful degradation)
            result.shouldDepositYield = SettingsValidationLibrary.validateYieldOptIn(result.amountAfterFee, true);
        } else {
            result.shouldDepositYield = false;
        }

        return result;
    }

    /**
     * @dev Best-effort resolver lookup. Mirrors CreateOps._getDisputeResolverForNewEscrow.
     */
    function _getDisputeResolverForNewEscrow(
        address resolutionModule,
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount,
        address escrowContract
    ) internal view returns (address resolver) {
        if (resolutionModule == address(0)) {
            return address(0);
        }

        // Check if resolutionModule is a contract (has code)
        if (resolutionModule.code.length == 0) {
            return address(0);
        }

        // Use low-level staticcall to query module
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(token, from, to, amount, address(0)); // Pass address(0) for releaseAddress as it's not relevant for resolver lookup
        (bool success, bytes memory data) = resolutionModule.staticcall(
            abi.encodeWithSelector(
                IResolutionModule.getDisputeResolver.selector,
                workflowId,
                escrowContract,
                escrowData
            )
        );

        if (!success || data.length < 64) {
            return address(0);
        }

        (resolver, ) = abi.decode(data, (address, uint8));
        return resolver;
    }
}
