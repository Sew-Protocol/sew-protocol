// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../interfaces/IYieldModule.sol';
import '../interfaces/aave/AaveV3Interfaces.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable2Step.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';

/**
 * @title AaveYieldModule
 * @notice Simplified Aave V3 yield module implementing IYieldModule v2.5
 *
 * This module is responsible for:
 * - Depositing tokens into Aave V3
 * - Tracking positions by (escrow, escrowId)
 * - Withdrawing from Aave and returning to escrow
 * - Operator/escrow-triggered unwind (recovery initiation) on normal withdrawal failure
 *
 * The escrow is responsible for:
 * - Initializing yield (calling initializeYield)
 * - Computing yield amounts and distribution
 * - Handling all authorization and fund flow
 *
 * This separation keeps modules simple and distribution policy in core.
 */
contract AaveYieldModule is IYieldModule, ERC165, Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ============ Types ============

    struct YieldPosition {
        address token;
        uint256 principalDeposited;  // INVARIANT 4: actual accepted amount, not requested
        uint256 aTokenShares;        // scaled (index-independent) aToken share delta at deposit time
        address aToken;              // aToken this position was created with (finding #5)
    }

    // ============ Storage ============

    // Aave pool reference
    IAavePool public immutable aavePool;

    // Module metadata
    string public constant MODULE_NAME = "AaveYieldModule";
    string public constant MODULE_VERSION = "2.5.2";
    bytes32 public constant PROTOCOL_ID = keccak256("aave-v3");

    // Authorization: approved escrow contracts
    mapping(address escrow => bool) public approvedEscrows;

    // Position tracking: (escrow => (escrowId => position))
    mapping(address escrow => mapping(uint256 escrowId => YieldPosition)) public positions;

    // Token to aToken mapping (Aave V3 reserve configuration)
    // Must be set by owner before tokens can be deposited
    mapping(address token => address aToken) public tokenToAToken;

    // Per-token minimum accepted deposit amount (in underlying token decimals).
    // If unset (0), defaults to 1 unit to avoid accidental zero-value/noise positions.
    mapping(address token => uint256 minDepositByToken) public minDepositByToken;

    // Recovery operators (e.g. GuardianOps) authorized to unwind positions on behalf
    // of approved escrows during an incident. The escrow itself is always authorized
    // to operate on its own positions.
    mapping(address operator => bool) public recoveryOperators;

    // ============ Events ============

    event EscrowApproved(address indexed escrow);
    event EscrowRevoked(address indexed escrow);
    event TokenConfigured(address indexed token, address indexed aToken);
    event MinDepositConfigured(address indexed token, uint256 minDeposit);
    event RecoveryOperatorSet(address indexed operator, bool allowed);

    // ============ Errors ============

    error TokenNotConfigured(address token);

    // ============ Constructor ============

    constructor(address _aavePool) Ownable(msg.sender) {
        require(_aavePool != address(0), "InvalidPoolAddress");
        require(_aavePool.code.length > 0, "PoolAddressIsNotContract");
        aavePool = IAavePool(_aavePool);
    }

    // ============ Authorization ============

    modifier onlyEscrow() {
        require(approvedEscrows[msg.sender], "UnauthorizedEscrow");
        _;
    }

    /**
     * @notice Approve an escrow contract to use this module
     * @param escrow Address to approve
     */
    function approveEscrow(address escrow) external onlyOwner {
        require(escrow != address(0), "InvalidAddress");
        approvedEscrows[escrow] = true;
        emit EscrowApproved(escrow);
    }

    /**
     * @notice Revoke approval for an escrow contract.
     * @dev Revocation blocks NEW deposits (initializeYield) but does NOT freeze exiting an
     *      existing position: the owning escrow may still unwindToEscrow / emergencyUnwind,
     *      and a recovery operator may still emergencyUnwindForEscrow. (finding #3)
     * @param escrow Address to revoke
     */
    function revokeEscrow(address escrow) external onlyOwner {
        approvedEscrows[escrow] = false;
        emit EscrowRevoked(escrow);
    }

    /**
     * @notice Configure aToken address for a token (must be called before deposits)
     * @param token Underlying token address
     * @param aToken Aave aToken address for this underlying
     */
    function configureToken(address token, address aToken) external onlyOwner {
        require(token != address(0), "InvalidAddress");
        require(aToken != address(0), "InvalidAToken");
        tokenToAToken[token] = aToken;
        emit TokenConfigured(token, aToken);
    }

    /**
     * @notice Configure per-token minimum accepted deposit amount.
     */
    function configureMinDeposit(address token, uint256 minDeposit) external onlyOwner {
        require(token != address(0), "InvalidAddress");
        minDepositByToken[token] = minDeposit;
        emit MinDepositConfigured(token, minDeposit);
    }

    /**
     * @notice Grant/revoke recovery-operator status for an address (e.g. GuardianOps)
     * @param operator Address to authorize or deauthorize
     * @param allowed True to grant recovery-operator status
     * @dev Recovery operators may unwind an approved escrow's position during an incident.
     *      Proceeds always go to the escrow owner, never to the operator.
     */
    function setRecoveryOperator(address operator, bool allowed) external onlyOwner {
        require(operator != address(0), "InvalidAddress");
        recoveryOperators[operator] = allowed;
        emit RecoveryOperatorSet(operator, allowed);
    }

    // ============ Core Yield Operations ============

    /**
     * @notice Initialize yield position in Aave
     * @param escrowId Escrow identifier
     * @param token Token to deposit
     * @param amount Amount to deposit
     * @param yieldMode Yield preset (currently unused, for future flexibility)
     * @return accepted Amount actually deposited
     *
     * INVARIANT 4: We track principalDeposited (actual accepted), not requested amount.
     * aTokenShares records the exact scaled aToken share delta so that multiple concurrent
     * positions for the same token do not interfere with each other on withdrawal.
     */
    function initializeYield(
        uint256 escrowId,
        address token,
        uint256 amount,
        YieldPreset yieldMode
    ) external onlyEscrow returns (uint256 accepted) {
        require(amount > 0, "ZeroAmount");

        // Guard against a second initialization silently overwriting an existing
        // (escrow, escrowId) position. Otherwise the aTokens already supplied for the
        // first position would remain owned by the module but no longer attributable
        // to any position, orphaning them.
        require(positions[msg.sender][escrowId].aTokenShares == 0, "PositionAlreadyExists");

        address aToken = _getAToken(token);

        uint256 minDeposit = minDepositByToken[token];
        if (minDeposit == 0) minDeposit = 1;
        require(amount >= minDeposit, "BelowMinDeposit");

        // PULL model: the escrow approves this module (EscrowVault/_depositForYield
        // already grants an allowance) and we pull the requested principal from it.
        // For fee-on-transfer tokens, fewer tokens than `amount` are credited.
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        uint256 received = balBefore < IERC20(token).balanceOf(address(this))
            ? IERC20(token).balanceOf(address(this)) - balBefore
            : 0;
        require(received > 0, "InsufficientBalance");

        // Module balance immediately after pulling the principal. Used below to measure
        // how much the supply call actually moved into the pool.
        uint256 balanceAfterPull = IERC20(token).balanceOf(address(this));

        // Snapshot scaled aToken balance before deposit to record exact scaled shares.
        // scaledBalanceOf is index-independent, so the recorded share is not affected by
        // yield accrued before this deposit and is converted to underlying exactly once at unwind.
        uint256 aTokenBefore = IAaveAToken(aToken).scaledBalanceOf(address(this));

        // Approve pool to pull the underlying we received and deposit to Aave
        SafeERC20.forceApprove(IERC20(token), address(aavePool), received);
        aavePool.supply(token, received, address(this), 0);

        // actualDeposited = the module-balance delta across the supply call
        // (balanceAfterPull - balanceAfterSupply). Unlike `received - balanceOf(this)`,
        // this is robust to a stray/donated pre-existing module balance: the pre-existing
        // amount is the same on both sides of supply, so it cancels out. Without this,
        // any existing balance is wrongly attributed to the new deposit and can even
        // drive actualDeposited to zero (reverting the deposit) or understate principal.
        uint256 balAfterSupply = IERC20(token).balanceOf(address(this));
        uint256 actualDeposited = balanceAfterPull > balAfterSupply ? balanceAfterPull - balAfterSupply : 0;
        require(actualDeposited > 0, "InsufficientBalance");

        // Record the exact scaled shares received for this position (INVARIANT 4).
        // Using scaledBalanceOf (rather than the rebased balanceOf delta) avoids
        // double-counting the liquidity index when the position is later valued at unwind.
        uint256 aTokenAfter = IAaveAToken(aToken).scaledBalanceOf(address(this));
        uint256 aTokenShares = aTokenAfter > aTokenBefore ? aTokenAfter - aTokenBefore : 0;
        require(aTokenShares > 0, "NoATokenSharesReceived");

        // Store position with actual deposited amount and aToken shares (INVARIANT 4)
        positions[msg.sender][escrowId] = YieldPosition({
            token: token,
            principalDeposited: actualDeposited,
            aTokenShares: aTokenShares,
            aToken: aToken
        });

        emit YieldInitialized(escrowId, token, actualDeposited, yieldMode);

        return actualDeposited;
    }

    /**
     * @notice Withdraw yield position from Aave
     * @param escrowId Escrow identifier
     * @param token Token to withdraw
     * @return principalOut Principal amount
     * @return yieldOut Yield amount
     *
     * INVARIANT 5: Escrow will do delta check (balBefore/balAfter) to verify funds.
     * Only withdraws the aToken shares recorded for this specific position — multiple
     * concurrent positions for the same token do not drain each other.
     */
    function unwindToEscrow(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external returns (uint256 principalOut, uint256 yieldOut) {
        // Approval gates NEW deposits only; a revoked escrow may still close a position
        // it owns (ownership proven by the recorded position). (finding #3)
        require(
            approvedEscrows[msg.sender] || positions[msg.sender][escrowId].aTokenShares > 0,
            "UnauthorizedEscrow"
        );
        YieldPosition memory pos = positions[msg.sender][escrowId];
        require(pos.token == token, "TokenMismatch");
        require(pos.aTokenShares > 0, "NoPosition");

        // finding #7: the caller-supplied expected principal must equal the recorded
        // principal. Core stores the module's accepted amount (v25YieldPrincipals) and
        // passes it here, so equality is a cross-component integrity check against a
        // re-deposit overwrite or mis-recording.
        require(principalExpected == pos.principalDeposited, "PrincipalMismatch");

        // Withdraw only our position's scaled shares (converted to underlying once).
        // Use the aToken recorded at deposit (finding #5): later changes to tokenToAToken
        // must NOT redirect an existing position to a different aToken.
        address aToken = pos.aToken;
        // currentATokenBalance (rebased) caps the withdrawal at what the module actually holds.
        uint256 currentATokenBalance = IERC20(aToken).balanceOf(address(this));
        // pos.aTokenShares is the scaled (index-independent) share count recorded at deposit.
        // Convert to current underlying value exactly once: scaled * currentIndex / 1e27.
        // This includes yield accrued since deposit without double-counting the index.
        uint256 currentIndex = aavePool.getReserveNormalizedIncome(token);
        require(currentIndex > 0, "InvalidIncomeIndex");
        uint256 positionCurrentValue = Math.mulDiv(pos.aTokenShares, currentIndex, 1e27);
        uint256 underlyingToWithdraw = positionCurrentValue <= currentATokenBalance
            ? positionCurrentValue
            : currentATokenBalance;
        require(underlyingToWithdraw > 0, "NoATokenBalance");

        // CEI (finding #9): clear the position BEFORE any external call so a reentrancy
        // attempt cannot observe a live position mid-unwind. A reverting external call
        // restores the deleted state anyway, so this is safe.
        delete positions[msg.sender][escrowId];

        // Withdraw from Aave back to us
        uint256 totalReceived = aavePool.withdraw(token, underlyingToWithdraw, address(this));

        // Transfer everything back to escrow (msg.sender)
        // INVARIANT 2: Only send to msg.sender (the escrow)
        IERC20(token).safeTransfer(msg.sender, totalReceived);

        // Calculate yield
        // INVARIANT 4: principalDeposited (actual accepted) is authoritative; principalExpected is validated == principalDeposited (finding #7)
        // INVARIANT 1: Never overstate principal. If Aave returned less than the deposited
        // principal (e.g. share-price drawdown), report only what was actually recovered so
        // the escrow never claims more than was physically returned. yield stays at 0.
        uint256 principal = pos.principalDeposited;
        if (totalReceived < principal) {
            principal = totalReceived;
        }
        uint256 yield = totalReceived > principal ? totalReceived - principal : 0;

        emit YieldWithdrawn(escrowId, token, principal, yield);

        return (principal, yield);
    }

    /**
     * @notice Escrow-triggered unwind of the caller's own position (fallback to unwindToEscrow)
     * @param escrowId Escrow identifier
     * @param token Token to recover
     * @param principalExpected Expected principal
     * @return recovered Amount recovered
     *
     * @dev finding #4: this is an OPERATOR/ESCROW-TRIGGERED unwind, NOT an independent
     *      Aave recovery mechanism. It calls the SAME aavePool.withdraw() as unwindToEscrow,
     *      so it fails for the same reasons a normal withdrawal would (Aave pause, no
     *      liquidity, pool malfunction). Its value is that it can be initiated by the escrow
     *      itself or (via emergencyUnwindForEscrow) by an authorized recovery operator, with
     *      proceeds ALWAYS forced to the escrow owner. It does NOT bypass Aave's own path.
     *
     * INVARIANT 1: MUST return funds or REVERT
     * INVARIANT 6: Strict semantics - return > 0 or revert, never return 0
     */
    function emergencyUnwind(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external returns (uint256 recovered) {
        // Same decoupling: a revoked escrow may still recover a position it owns. (finding #3)
        require(
            approvedEscrows[msg.sender] || positions[msg.sender][escrowId].aTokenShares > 0,
            "UnauthorizedEscrow"
        );
        return _emergencyUnwind(msg.sender, escrowId, token, principalExpected);
    }

    /**
     * @notice Recovery-operator/escrow-triggered unwind of a named escrow's position
     * @param escrow The escrow contract that owns the position
     * @param escrowId Escrow identifier
     * @param token Token to recover
     * @param principalExpected Expected principal
     * @return recovered Amount recovered
     * @dev finding #4: like emergencyUnwind, this is authorized third-party initiation of
     *      the SAME Aave withdrawal path, not an alternate recovery mechanism — it reverts
     *      if aavePool.withdraw() reverts. Proceeds ALWAYS go to `escrow`, never to the
     *      caller. GuardianOps layers cooldown + per-call cap guardrails on top when it
     *      invokes this. Callable by the position owner or an approved recovery operator.
     *      INVARIANT 6: returns > 0 or reverts, never 0.
     */
    function emergencyUnwindForEscrow(
        address escrow,
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external returns (uint256 recovered) {
        // Escrow approval gates NEW exposure only; recovery may proceed on existing
        // positions even after revokeEscrow. (finding #3)
        require(msg.sender == escrow || recoveryOperators[msg.sender], "UnauthorizedEscrow");
        return _emergencyUnwind(escrow, escrowId, token, principalExpected);
    }

    /**
     * @notice Shared unwind logic operating on a named escrow owner.
     * @dev finding #4: uses the same aavePool.withdraw() as normal unwind; provides
     *      third-party initiation + forced-to-escrow routing, not an independent Aave exit.
     *      INVARIANT 2: Funds are only ever sent back to the escrow owner.
     *      INVARIANT 6: returns > 0 or reverts, never 0.
     */
    function _emergencyUnwind(
        address escrowOwner,
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) internal returns (uint256 recovered) {
        YieldPosition memory pos = positions[escrowOwner][escrowId];
        require(pos.token == token, "TokenMismatch");
        require(pos.aTokenShares > 0, "NoPosition");

        // finding #7: ensure the caller-expected principal matches the recorded principal.
        require(principalExpected == pos.principalDeposited, "PrincipalMismatch");

        // aToken recorded at deposit (finding #5) — immune to later config changes.
        address aToken = pos.aToken;
        uint256 currentATokenBalance = IERC20(aToken).balanceOf(address(this));

        uint256 currentIndex = aavePool.getReserveNormalizedIncome(token);
        require(currentIndex > 0, "InvalidIncomeIndex");
        uint256 positionCurrentValue = Math.mulDiv(pos.aTokenShares, currentIndex, 1e27);
        uint256 underlyingToWithdraw = positionCurrentValue <= currentATokenBalance
            ? positionCurrentValue
            : currentATokenBalance;

        if (underlyingToWithdraw == 0) {
            revert("NoATokenBalance");
        }

        // CEI (finding #9): clear the position BEFORE the external withdraw+transfer so a
        // reentrancy attempt cannot observe a live position. Revert restores deleted state.
        delete positions[escrowOwner][escrowId];

        // Try to withdraw
        uint256 out = aavePool.withdraw(token, underlyingToWithdraw, address(this));

        // Transfer to the escrow owner (never the caller/operator)
        IERC20(token).safeTransfer(escrowOwner, out);

        // INVARIANT 6: Strict semantics - never return 0
        if (out == 0) {
            revert("EmergencyUnwindReturnedZero");
        }

        emit EmergencyUnwindExecuted(escrowId, token, out, keccak256("emergency_unwind"));

        return out;
    }

    // ============ Metadata ============

    /**
     * @notice Check if module can handle this token/amount
     * @param token Token to check
     * @return supported Whether supported
     * @return reasonCode Error code (0x0 = OK)
     */
    function canHandle(
        address token,
        YieldPreset, /* mode */
        uint256 amount
    ) external view returns (bool supported, bytes32 reasonCode) {
        // Mirror the cheap, deterministic admissibility checks that initializeYield
        // enforces, so canHandle never reports "supported" for a call that
        // initializeYield would reject immediately. Reduced to view-only, caller-visible
        // conditions (token/amount); the (msg.sender, escrowId)-dependent
        // PositionAlreadyExists check is intentionally not applied here.
        if (amount == 0) {
            return (false, keccak256("ZERO_AMOUNT"));
        }
        if (tokenToAToken[token] == address(0)) {
            return (false, keccak256("TOKEN_NOT_CONFIGURED"));
        }
        uint256 minDeposit = minDepositByToken[token];
        if (minDeposit == 0) minDeposit = 1;
        if (amount < minDeposit) {
            return (false, keccak256("BELOW_MIN_DEPOSIT"));
        }
        return (true, 0x0);
    }

    /**
     * @notice Get module metadata
     */
    function getModuleInfo()
        external pure returns (string memory name, string memory version, bytes32 protocolId) {
        return (MODULE_NAME, MODULE_VERSION, PROTOCOL_ID);
    }

    /**
     * @notice Preview the tracked position for an escrow (IYieldModule view).
     * @dev Best-effort; returns inactive/zero for unknown positions.
     */
    function previewPosition(
        uint256 escrowId,
        address escrowContract
    ) external view returns (uint256 principal, uint256 currentValue, bool isActive) {
        YieldPosition memory pos = positions[escrowContract][escrowId];
        principal = pos.principalDeposited;
        isActive = principal > 0;
        currentValue = principal;
        if (isActive && pos.aTokenShares > 0) {
            if (pos.aToken != address(0)) {
                uint256 currentIndex = aavePool.getReserveNormalizedIncome(pos.token);
                if (currentIndex > 0) {
                    currentValue = Math.mulDiv(pos.aTokenShares, currentIndex, 1e27);
                }
            }
        }
    }

    /// @notice ERC-165: advertises IYieldModule (v2.5) support for registry validation.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IYieldModule).interfaceId || super.supportsInterface(interfaceId);
    }

    // ============ Helpers ============

    /**
     * @notice Get aToken address for underlying token, reverts if not configured
     */
    function _getAToken(address token) internal view returns (address aToken) {
        aToken = tokenToAToken[token];
        if (aToken == address(0)) revert TokenNotConfigured(token);
    }
}
