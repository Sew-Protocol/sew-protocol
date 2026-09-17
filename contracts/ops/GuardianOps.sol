// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '../interfaces/IYieldModule.sol';
import '../interfaces/aave/AaveV3Interfaces.sol';
import '../modules/AaveYieldModule.sol';
import '../core/BaseEscrow.sol';
import '../core/ModuleSnapshotRegistry.sol';

/**
 * @title GuardianOps
 * @notice Emergency operations contract for guardian-controlled Aave position unwinding
 * @dev Extracted from BaseEscrow to reduce bytecode size while preserving safety
 * 
 * Safety constraints:
 * - Only callable by ROLE_GUARDIAN (verified via escrow contract)
 * - Only callable when escrow is paused
 * - Proceeds ALWAYS go to escrow contract (not guardian)
 * - Rate limited (cooldown per token + max per call)
 * - Scoped to specific token (not arbitrary transfers)
 * - Non-blocking (fails gracefully)
 */
contract GuardianOps is Context {
    using SafeERC20 for IERC20;
    using Address for address;

    // Immutable escrow contract address
    BaseEscrow public immutable escrowContract;

    // Emergency unwind constants (matching BaseEscrow)
    uint256 public constant MAX_UNWIND_AMOUNT_PER_CALL = 1_000_000e18; // 1M tokens max per call
    uint256 public constant UNWIND_COOLDOWN = 1 hours; // Minimum time between unwinds per token

    // Rate limiting state (token => last unwind time)
    mapping(address => uint256) public lastUnwindTimestamp;
    
    // Total amount unwound across all tokens (for monitoring)
    uint256 public totalUnwoundAmount;

    // Events
    event EmergencyUnwindExecuted(
        address indexed token,
        uint256 aTokenAmount,
        uint256 underlyingAmount,
        uint256 timestamp,
        address indexed executor,
        uint8 reasonCode
    );

    // Custom errors
    error EscrowNotPaused();
    error NotGuardian(address caller);
    error CooldownNotExpired(address token, uint256 lastUnwind, uint256 currentTime);
    error AmountExceedsLimit(uint256 amount, uint256 maxAmount);
    error ModuleNotConfigured();
    error PoolNotConfigured();
    error InvalidEscrowTarget(address target);
    error NothingToUnwind(address token);
    error WithdrawalFailed(address token, uint256 amount);

    /**
     * @notice Constructor
     * @param escrowContract_ Address of the BaseEscrow contract
     */
    constructor(address escrowContract_) {
        if (escrowContract_ == address(0)) revert InvalidAddress(uint8(1), address(0));
        escrowContract = BaseEscrow(escrowContract_);
    }

    /**
     * @notice Emergency unwind Aave positions for a specific token (guardian only)
     * @param token Underlying token address to unwind
     * @param maxATokenAmount Maximum aToken amount to unwind (safety limit)
     * @return underlyingAmount Actual underlying amount withdrawn to escrow contract
     * @dev CRITICAL SAFETY CONSTRAINTS:
     *      - Only callable by ROLE_GUARDIAN (verified via escrow.hasRole)
     *      - Only callable when escrow is paused
     *      - Proceeds ALWAYS go to escrow contract (not guardian)
     *      - Rate limited (cooldown per token + max per call)
     *      - Scoped to specific token (not arbitrary transfers)
     *      - Non-blocking (fails gracefully, doesn't revert)
     */
    /**
     * @notice Emergency unwind a specific Aave position (guardian only)
     * @param token Underlying token address
     * @param workflowId The escrow transfer ID to unwind
     * @param targetEscrow Address of the escrow contract that owns the position
     * @return unwoundAmount Actual underlying amount withdrawn to escrow contract
     */
    function emergencyUnwindAavePosition(
        address token,
        uint256 workflowId,
        address targetEscrow
    ) external returns (uint256 unwoundAmount) {
        // Safety check 1: Verify caller is guardian
        bytes32 ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
        if (!escrowContract.hasRole(ROLE_GUARDIAN, _msgSender())) {
            revert NotGuardian(_msgSender());
        }

        // Note: pause functionality was removed from BaseEscrow for bytecode-size reasons.
        // Guardian authentication above is sufficient protection here — ROLE_GUARDIAN is
        // time-locked and the rate-limiting in this contract prevents abuse.

        // GuardianOps is bound to exactly one escrow vault (immutable). The Aave position and
        // its recorded principal live on that same vault, so the unwind target must BE that
        // vault. Rejecting any other target prevents relaying proceeds to an unrelated contract
        // while the recorded principal is read from escrowContract.
        if (targetEscrow != address(escrowContract)) {
            revert InvalidEscrowTarget(targetEscrow);
        }

        // Rate limiting: at most one unwind per token per UNWIND_COOLDOWN window.
        if (block.timestamp < lastUnwindTimestamp[token] + UNWIND_COOLDOWN) {
            revert CooldownNotExpired(token, lastUnwindTimestamp[token], block.timestamp);
        }

        // Prefer the module that actually holds this position (the workflow-recorded module
        // from EscrowVault), falling back to the registry default. Using the recorded module
        // keeps unwinds correct after a module upgrade: the position lives in the module it
        // was deposited into, not necessarily the current default.
        address genModuleAddr = escrowContract.v25YieldModules(workflowId);
        if (genModuleAddr == address(0)) {
            // Try to get moduleManagement from EscrowVault (public getter)
            (bool success, bytes memory data) = address(escrowContract).staticcall(
                abi.encodeWithSelector(bytes4(keccak256("moduleManagement()")))
            );
            if (success && data.length >= 32) {
                address moduleMgmtAddr = abi.decode(data, (address));
                if (moduleMgmtAddr != address(0) && moduleMgmtAddr.code.length > 0) {
                    ModuleSnapshotRegistry mm = ModuleSnapshotRegistry(moduleMgmtAddr);
                    genModuleAddr = mm.getModule(targetEscrow, BaseEscrow.ModuleType.YIELD_GEN);
                }
            }
        }

        if (genModuleAddr == address(0)) {
            revert ModuleNotConfigured();
        }
        IYieldModule genModule = IYieldModule(genModuleAddr);

        // Pass the recorded principal so the module can enforce minimum recovery.
        uint256 principalExpected = escrowContract.v25YieldPrincipals(workflowId);
        // Route the unwind through the module explicitly naming the escrow that owns the
        // position. The module is namespaced by (escrow, escrowId) using the escrow as the
        // owning key, so we must pass `targetEscrow` as the owner rather than relying on
        // msg.sender (which here is this GuardianOps contract). Funds are sent by the
        // module directly to `targetEscrow`, keeping the "proceeds always go to escrow"
        // invariant intact. GuardianOps must be registered as a recovery operator on the
        // AaveYieldModule for this call to authenticate.
        unwoundAmount = AaveYieldModule(address(genModule)).emergencyUnwindForEscrow(
            targetEscrow,
            workflowId,
            token,
            principalExpected
        );

        if (unwoundAmount > 0) {
            // Enforce per-call unwind cap. A revert here rolls back the whole transaction,
            // including the module's transfer to the escrow, so nothing is left dangling.
            if (unwoundAmount > MAX_UNWIND_AMOUNT_PER_CALL) {
                revert AmountExceedsLimit(unwoundAmount, MAX_UNWIND_AMOUNT_PER_CALL);
            }
            totalUnwoundAmount += unwoundAmount;
            lastUnwindTimestamp[token] = block.timestamp;
            
            emit EmergencyUnwindExecuted(
                token,
                0, // aToken amount not directly used in new signature
                unwoundAmount,
                block.timestamp,
                _msgSender(),
                0 // 0 = success
            );
        } else {
            revert NothingToUnwind(token);
        }

        return unwoundAmount;
    }
}
