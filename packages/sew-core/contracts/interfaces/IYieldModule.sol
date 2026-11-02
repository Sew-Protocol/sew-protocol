// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../types/YieldPresets.sol';

/**
 * @title IYieldModule
 * @notice Unified interface for yield generation modules
 * 
 * DESIGN PRINCIPLE: Modules are responsible for yield generation mechanics
 * (deposit, track, withdraw). Escrows are responsible for distribution policy
 * (who gets principal, how yield splits, fee routing).
 * 
 * This separation ensures:
 * - Policy consistency (one source of truth in core)
 * - Module simplicity (just protocol integration)
 * - Fund safety (clear invariants)
 * - Easy extensibility (add protocols without touching core)
 * 
 * FUND FLOW INVARIANT:
 * 1. Escrow transfers principal to module
 * 2. Module deposits into protocol (Aave, Morpho, etc.)
 * 3. Module tracks positions by (caller/escrow, escrowId)
 * 4. On unwind: module withdraws to escrow
 * 5. Module NEVER sends funds to arbitrary recipients
 * 6. Module ONLY returns funds to msg.sender (the escrow)
 * 
 * AUTHORIZATION INVARIANT:
 * - Module checks msg.sender is an approved escrow
 * - Module state is namespaced by (msg.sender, escrowId)
 * - This prevents griefing and state collisions
 * 
 * SAFETY INVARIANTS:
 * - INVARIANT 1: No silent fund loss (emergency recovery required, revert if impossible)
 * - INVARIANT 2: Module cannot redirect funds (onlyEscrow gating, state namespacing)
 * - INVARIANT 3: Distribution policy is canonical (in core, not module)
 * - INVARIANT 4: Principal accounting correct (store accepted amount, not requested)
 * - INVARIANT 5: Balance verification provable (delta check, not absolute)
 * - INVARIANT 6: emergencyUnwind strict semantics (return > 0 or revert, never 0)
 */
interface IYieldModule {
    
    // ============ Core Operations ============
    
    /**
     * @notice Initialize yield position
     * @param escrowId Unique escrow identifier
     * @param token Token to yield on
     * @param amount Amount to deposit
     * @param yieldMode Preset (OFF, ENABLED, TO_RECIPIENT, etc.)
     * @return accepted Amount actually accepted for yielding
     * 
     * @dev Called once per escrow during initialization
     * @dev Escrow transfers 'amount' to this contract before calling
     * @dev State stored namespaced by (msg.sender, escrowId)
     * @dev Must revert if cannot accept this token/amount
     * @dev Returns 'accepted' which may differ from 'amount' due to:
     *      - Fee-on-transfer tokens (accepted < amount)
     *      - Rebasing tokens (tracks units deposited)
     *      - Protocol limits (min/max constraints)
     * 
     * INVARIANT 4: Store accepted amount for yield calculation
     *      This is the basis for future principal/yield split
     */
    function initializeYield(
        uint256 escrowId,
        address token,
        uint256 amount,
        YieldPreset yieldMode
    ) external returns (uint256 accepted);
    
    /**
     * @notice Withdraw yield position back to escrow
     * @param escrowId Escrow identifier
     * @param token Token address
     * @param principalExpected Accepted principal the caller expects (must equal the module's
     *                          recorded principalDeposited; the module enforces this — finding #7)
     * @return principalOut Actual principal withdrawn
     * @return yieldOut Gross yield accrued (may be 0)
     * 
     * @dev Called during escrow release/cancellation
     * @dev Returns funds to msg.sender (the escrow contract)
     * @dev On failure: escrow will attempt emergencyUnwind
     * @dev Must preserve invariant: only send to msg.sender
     * @dev principalOut should match initializeYield's accepted amount
     *      yieldOut = total_withdrawn - principalOut
     */
    function unwindToEscrow(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external returns (uint256 principalOut, uint256 yieldOut);
    
    /**
     * @notice Emergency recovery path
     * @param escrowId Escrow identifier
     * @param token Token address
     * @param principalExpected Accepted principal the caller expects (must equal the module's
     *                          recorded principalDeposited — finding #7)
     * @return recovered Amount recovered (always > 0, or reverts)
     *
     * @dev Called after unwindToEscrow fails
     * @dev NOTE (finding #4): this is an escrow-triggered unwind, NOT an independent recovery
     *      mechanism. It uses the same protocol withdraw() path as normal unwinds, so an
     *      Aave-level failure (pause / no liquidity) reverts both. It guarantees strict
     *      semantics (return > 0 or revert), proceeds-only-to-msg.sender, and — where the
     *      module supports it — operator-triggered initiation.
     * @dev INVARIANT 6: MUST return funds or REVERT (never return 0)
     *      Strict semantics: return > 0 or fail
     *      No ambiguous "I tried and got nothing" states
     * @dev Returns funds to msg.sender only
     * @dev INVARIANT 1: MUST NOT silently abandon yield (emit event if needed)
     * @dev Best-effort recovery; if any recovery is possible, return it
     *      If recovery is impossible, revert with clear reason
     *
     * @dev FEE TREATMENT (policy, not accident): the emergency API returns an undifferentiated
     *      recovered amount — it does NOT classify principal vs yield. By design, core does not
     *      subject that recovery amount to normal yield-fee classification. This is deliberately
     *      asymmetric with the normal unwind contract:
     *        - Normal successful unwind classifies principal/yield and applies the snapshotted
     *          protocol yield fee (conservation R = P + B + F).
     *        - Emergency/recovery unwind restores recovered assets to the escrow WITHOUT
     *          applying a protocol yield fee.
     *      Recovery operators (and the escrow's own fallback) are privileged incident actors;
     *      choosing the recovery path may therefore waive protocol yield fees. This is accepted
     *      policy: recovery is a down-only remediation path, not a revenue path.
     */
    function emergencyUnwind(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external returns (uint256 recovered);
    
    // ============ Views ============

    /**
     * @notice Preview the current tracked position for an escrow.
     * @param escrowId Escrow identifier
     * @param escrowContract The escrow that owns the position (state is namespaced by escrow)
     * @return principal Recorded principal (accepted at initializeYield)
     * @return currentValue Current underlying value of the position (principal + accrued)
     * @return isActive Whether a position is recorded
     * @dev View-only, best-effort: implementations should not revert for unknown positions.
     */
    function previewPosition(
        uint256 escrowId,
        address escrowContract
    ) external view returns (uint256 principal, uint256 currentValue, bool isActive);

    // ============ Metadata & Validation ============
    
    /**
     * @notice Check if module can handle this token/amount
     * @param token Token address
     * @param mode Yield mode
     * @param amount Amount to deposit
     * @return supported Whether supported
     * @return reasonCode Error code if not (0x0 = OK, else specific reason)
     * 
     * @dev Used for preflight checks; initializeYield may still revert
     * @dev Reason codes are keccak256 hashes of stable strings (e.g. keccak256("TOKEN_NOT_CONFIGURED"), keccak256("ZERO_AMOUNT"), keccak256("BELOW_MIN_DEPOSIT")); 0x0 means OK.
     * @dev Not safety-critical; initializeYield is the authoritative check
     */
    function canHandle(
        address token,
        YieldPreset mode,
        uint256 amount
    ) external view returns (bool supported, bytes32 reasonCode);
    
    /**
     * @notice Get module metadata
     * @return name Module name (e.g., "AaveYieldModule")
     * @return version Version (e.g., "1.0.0")
     * @return protocolId Unique ID (e.g., keccak256("aave-v3"))
     */
    function getModuleInfo()
        external view returns (string memory name, string memory version, bytes32 protocolId);
    
    // ============ Events ============
    
    /**
     * @notice Emitted when yield is initialized
     * @param escrowId The escrow identifier
     * @param token The token address
     * @param principalDeposited Actual amount deposited (after fees)
     * @param yieldMode The yield configuration
     */
    event YieldInitialized(
        uint256 indexed escrowId,
        address indexed token,
        uint256 principalDeposited,
        YieldPreset yieldMode
    );
    
    /**
     * @notice Emitted when yield is withdrawn
     * @param escrowId The escrow identifier
     * @param token The token address
     * @param principalOut Principal amount withdrawn
     * @param yieldOut Yield amount accrued
     */
    event YieldWithdrawn(
        uint256 indexed escrowId,
        address indexed token,
        uint256 principalOut,
        uint256 yieldOut
    );
    
    /**
     * @notice Emitted on emergency recovery
     * @param escrowId The escrow identifier
     * @param token The token address
     * @param recovered Amount recovered
     * @param reason Description of recovery (e.g., "emergency_unwind")
     */
    event EmergencyUnwindExecuted(
        uint256 indexed escrowId,
        address indexed token,
        uint256 recovered,
        bytes32 reason
    );
}
