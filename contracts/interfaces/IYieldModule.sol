// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

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
     * @param yieldMode Preset (OFF, TO_SENDER, TO_RECIPIENT, etc.)
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
     * @param principalExpected Expected principal (for validation)
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
     * @param principalExpected Expected principal
     * @return recovered Amount recovered (always > 0, or reverts)
     * 
     * @dev Called after unwindToEscrow fails
     * @dev INVARIANT 6: MUST return funds or REVERT (never return 0)
     *      Strict semantics: return > 0 or fail
     *      No ambiguous "I tried and got nothing" states
     * @dev Returns funds to msg.sender only
     * @dev INVARIANT 1: MUST NOT silently abandon yield (emit event if needed)
     * @dev Best-effort recovery; if any recovery is possible, return it
     *      If recovery is impossible, revert with clear reason
     */
    function emergencyUnwind(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external returns (uint256 recovered);
    
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
     * @dev Reason codes: 0x0 (OK), 0x1 (token not supported), etc.
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
