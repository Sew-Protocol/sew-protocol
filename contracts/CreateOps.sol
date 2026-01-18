// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import './types/EscrowTypes.sol';
import './types/YieldPresets.sol';
import './libraries/SettingsValidationLibrary.sol';
import './libraries/YieldPresetLibrary.sol';
import './libraries/EscrowEncodingLibrary.sol';
import './shared/interfaces/IResolutionModule.sol';
import './interfaces/IYieldGenerationModule.sol';

/**
 * @title CreateOps
 * @notice External contract for escrow creation validation and computation
 * @dev Extracted from BaseEscrow to reduce contract size (Phase 3 size optimization)
 *
 *      Key design principles:
 *      - Compute → Apply: Returns creation result, BaseEscrow applies to state
 *      - No state writes: Does not modify BaseEscrow state
 *      - Validation only: Validates inputs and computes values
 *      - View-ish: Could be view functions but may query modules
 *      - Access Control: Restricted to authorized escrow contracts only
 *
 *      Pattern:
 *      BaseEscrow calls: computeEscrowCreation(...)
 *      CreateOps returns: (fee, amountAfterFee, resolver, yieldEnabled, shouldDepositYield)
 *      BaseEscrow applies: Stores struct, updates balances, emits events
 */
contract CreateOps is AccessControl {
    uint256 private constant ESCROW_FEE_DENOMINATOR = 10000;
    
    // ============ Role Constants ============
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');
    
    // ============ Custom Errors ============
    error ZeroOwner();
    error UnauthorizedEscrowContract(address caller);
    
    /**
     * @notice Constructor for CreateOps
     * @param initialOwner Address that will receive DEFAULT_ADMIN_ROLE
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }
    
    /**
     * @notice Register an escrow contract that can call computeEscrowCreation
     * @param escrow Address of the escrow contract (EscrowVault or EscrowableERC20)
     * @dev Only callable by admin. Escrow contracts must be registered before use.
     */
    function registerEscrowContract(address escrow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (escrow == address(0)) revert InvalidAddress('Escrow contract cannot be zero', escrow);
        _grantRole(ROLE_ESCROW_CONTRACT, escrow);
    }
    
    /**
     * @dev Result of escrow creation computation
     */
    struct CreateResult {
        uint256 fee;                    // Escrow fee amount
        uint256 amountAfterFee;         // Amount after fee deduction
        address resolver;               // Default resolver address
        bool yieldEnabled;              // Whether yield is enabled for this escrow
        bool shouldDepositYield;        // Whether to attempt yield deposit
    }

    /**
     * @notice Compute escrow creation parameters
     * @param token Token address
     * @param to Recipient address
     * @param from Sender address
     * @param amount Total amount to escrow
     * @param settings Escrow configuration
     * @param escrowFee Escrow fee in basis points
     * @param workflowId The workflow ID (array index)
     * @param resolutionModule Resolution module address (for resolver determination)
     * @return result Creation computation result
     * @dev This function is "compute-only" - it does NOT modify BaseEscrow state.
     *      BaseEscrow will apply the result after receiving it.
     *      Restricted to authorized escrow contracts only (EscrowVault, EscrowableERC20).
     */
    function computeEscrowCreation(
        address token,
        address to,
        address from,
        uint256 amount,
        EscrowSettings memory settings,
        uint256 escrowFee,
        uint256 workflowId,
        address resolutionModule
    ) external view onlyRole(ROLE_ESCROW_CONTRACT) returns (CreateResult memory result) {
        // Validate amount
        if (amount == 0) revert AmountZero();
        SettingsValidationLibrary.validateEscrowAmount(amount);
        SettingsValidationLibrary.validateRecipient(to, from);
        SettingsValidationLibrary.validateEscrowSettings(settings, block.timestamp);

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
            result.amountAfterFee
        );

        // Yield configuration
        result.yieldEnabled = YieldPresetLibrary.isYieldEnabled(settings.yieldPreset);
        if (result.yieldEnabled) {
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
     * @notice Get dispute resolver for new escrow
     * @dev Queries resolution module for default resolver
     */
    function _getDisputeResolverForNewEscrow(
        address resolutionModule,
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount
    ) internal view returns (address resolver) {
        if (resolutionModule == address(0)) {
            return address(0);
        }

        // Use low-level staticcall to query module
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(token, from, to, amount);
        (bool success, bytes memory data) = resolutionModule.staticcall(
            abi.encodeWithSelector(
                IResolutionModule.getDisputeResolver.selector,
                workflowId,
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
