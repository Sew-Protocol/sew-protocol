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
 * - Emergency recovery on normal withdrawal failure
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
    }

    // ============ Storage ============

    // Aave pool reference
    IAavePool public immutable aavePool;

    // Module metadata
    string public constant MODULE_NAME = "AaveYieldModule";
    string public constant MODULE_VERSION = "2.5.1";
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
     * @notice Revoke approval for an escrow contract
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

        // Snapshot scaled aToken balance before deposit to record exact scaled shares.
        // scaledBalanceOf is index-independent, so the recorded share is not affected by
        // yield accrued before this deposit and is converted to underlying exactly once at unwind.
        uint256 aTokenBefore = IAaveAToken(aToken).scaledBalanceOf(address(this));

        // Approve pool to pull the underlying we received and deposit to Aave
        SafeERC20.forceApprove(IERC20(token), address(aavePool), received);
        aavePool.supply(token, received, address(this), 0);

        // Calculate actual deposited (handles fee-on-transfer dust left on the module)
        uint256 balAfter = IERC20(token).balanceOf(address(this));
        uint256 actualDeposited = received > balAfter ? received - balAfter : 0;
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
            aTokenShares: aTokenShares
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
        uint256 /* principalExpected */
    ) external onlyEscrow returns (uint256 principalOut, uint256 yieldOut) {
        YieldPosition memory pos = positions[msg.sender][escrowId];
        require(pos.token == token, "TokenMismatch");
        require(pos.aTokenShares > 0, "NoPosition");

        // Withdraw only our position's scaled shares (converted to underlying once).
        address aToken = _getAToken(token);
        // currentATokenBalance (rebased) caps the withdrawal at what the module actually holds.
        uint256 currentATokenBalance = IERC20(aToken).balanceOf(address(this));
        // pos.aTokenShares is the scaled (index-independent) share count recorded at deposit.
        // Convert to current underlying value exactly once: scaled * currentIndex / 1e27.
        // This includes yield accrued since deposit without double-counting the index.
        uint256 currentIndex = aavePool.getReserveNormalizedIncome(token);
        require(currentIndex > 0, "InvalidIncomeIndex");
        uint256 positionCurrentValue = Math.mulDiv(pos.aTokenShares, currentIndex, 1e27);
        uint256 sharesToWithdraw = positionCurrentValue <= currentATokenBalance
            ? positionCurrentValue
            : currentATokenBalance;
        require(sharesToWithdraw > 0, "NoATokenBalance");

        // Withdraw from Aave back to us
        uint256 totalReceived = aavePool.withdraw(token, sharesToWithdraw, address(this));

        // Transfer everything back to escrow (msg.sender)
        // INVARIANT 2: Only send to msg.sender (the escrow)
        IERC20(token).safeTransfer(msg.sender, totalReceived);

        // Calculate yield
        // INVARIANT 4: Use principalDeposited (actual accepted), not principalExpected
        // INVARIANT 1: Never overstate principal. If Aave returned less than the deposited
        // principal (e.g. share-price drawdown), report only what was actually recovered so
        // the escrow never claims more than was physically returned. yield stays at 0.
        uint256 principal = pos.principalDeposited;
        if (totalReceived < principal) {
            principal = totalReceived;
        }
        uint256 yield = totalReceived > principal ? totalReceived - principal : 0;

        // Clean up position
        delete positions[msg.sender][escrowId];

        emit YieldWithdrawn(escrowId, token, principal, yield);

        return (principal, yield);
    }

    /**
     * @notice Emergency recovery if normal unwind fails
     * @param escrowId Escrow identifier
     * @param token Token to recover
     * @param principalExpected Expected principal
     * @return recovered Amount recovered
     *
     * INVARIANT 1: MUST return funds or REVERT
     * INVARIANT 6: Strict semantics - return > 0 or revert, never return 0
     */
    function emergencyUnwind(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external onlyEscrow returns (uint256 recovered) {
        return _emergencyUnwind(msg.sender, escrowId, token, principalExpected);
    }

    /**
     * @notice Emergency recovery of a specific escrow's position (operator/escrow only)
     * @param escrow The escrow contract that owns the position
     * @param escrowId Escrow identifier
     * @param token Token to recover
     * @param principalExpected Expected principal
     * @return recovered Amount recovered
     * @dev A callable by the position owner, or by an approved recovery operator
     *      (e.g. GuardianOps) during an incident. Proceeds ALWAYS go to `escrow`,
     *      never to the caller. INVARIANT 6: returns > 0 or reverts, never 0.
     */
    function emergencyUnwindForEscrow(
        address escrow,
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external returns (uint256 recovered) {
        require(approvedEscrows[escrow], "UnauthorizedEscrow");
        require(msg.sender == escrow || recoveryOperators[msg.sender], "UnauthorizedEscrow");
        return _emergencyUnwind(escrow, escrowId, token, principalExpected);
    }

    /**
     * @notice Shared emergency unwind logic operating on a named escrow owner
     * @dev INVARIANT 2: Funds are only ever sent back to the escrow owner.
     */
    function _emergencyUnwind(
        address escrowOwner,
        uint256 escrowId,
        address token,
        uint256 /* principalExpected */
    ) internal returns (uint256 recovered) {
        YieldPosition memory pos = positions[escrowOwner][escrowId];
        require(pos.token == token, "TokenMismatch");
        require(pos.aTokenShares > 0, "NoPosition");

        address aToken = _getAToken(token);
        uint256 currentATokenBalance = IERC20(aToken).balanceOf(address(this));

        uint256 currentIndex = aavePool.getReserveNormalizedIncome(token);
        require(currentIndex > 0, "InvalidIncomeIndex");
        uint256 positionCurrentValue = Math.mulDiv(pos.aTokenShares, currentIndex, 1e27);
        uint256 sharesToWithdraw = positionCurrentValue <= currentATokenBalance
            ? positionCurrentValue
            : currentATokenBalance;

        if (sharesToWithdraw == 0) {
            revert("NoATokenBalance");
        }

        // Try to withdraw
        uint256 out = aavePool.withdraw(token, sharesToWithdraw, address(this));

        // Transfer to the escrow owner (never the caller/operator)
        IERC20(token).safeTransfer(escrowOwner, out);

        // Clean up
        delete positions[escrowOwner][escrowId];

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
        uint256      /* amount */
    ) external view returns (bool supported, bytes32 reasonCode) {
        if (tokenToAToken[token] == address(0)) {
            return (false, keccak256("TOKEN_NOT_CONFIGURED"));
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
            if (tokenToAToken[pos.token] != address(0)) {
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
