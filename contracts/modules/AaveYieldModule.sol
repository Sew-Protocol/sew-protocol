// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldModule.sol';
import '../interfaces/aave/AaveV3Interfaces.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable2Step.sol';

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
contract AaveYieldModule is IYieldModule, Ownable2Step {
    using SafeERC20 for IERC20;

    // ============ Types ============

    struct YieldPosition {
        address token;
        uint256 principalDeposited;  // INVARIANT 4: actual accepted amount, not requested
        uint256 aTokenShares;        // aToken balance delta at deposit time (per-position share)
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

    // ============ Events ============

    event EscrowApproved(address indexed escrow);
    event EscrowRevoked(address indexed escrow);
    event TokenConfigured(address indexed token, address indexed aToken);

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
     * aTokenShares records the exact aToken balance delta so that multiple concurrent
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

        // Escrow has already transferred 'amount' to us (push model)
        // Note: For fee-on-transfer tokens, balance may be less than amount
        uint256 balBefore = IERC20(token).balanceOf(address(this));

        // We can only deposit what we have
        uint256 available = balBefore;
        require(available > 0, "InsufficientBalance");

        // Snapshot aToken balance before deposit to calculate our exact share
        uint256 aTokenBefore = IERC20(aToken).balanceOf(address(this));

        // Approve pool to pull tokens (use available, not amount)
        SafeERC20.forceApprove(IERC20(token), address(aavePool), available);

        // Deposit to Aave
        aavePool.supply(token, available, address(this), 0);

        // Calculate actual deposited (handles fee-on-transfer)
        uint256 balAfter = IERC20(token).balanceOf(address(this));
        uint256 actualDeposited = balBefore > balAfter ? balBefore - balAfter : 0;

        require(actualDeposited > 0, "InsufficientBalance");

        // Calculate exact aToken shares received for this position
        uint256 aTokenAfter = IERC20(aToken).balanceOf(address(this));
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
     * @param principalExpected Expected principal (for validation)
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
    ) external onlyEscrow returns (uint256 principalOut, uint256 yieldOut) {
        YieldPosition memory pos = positions[msg.sender][escrowId];
        require(pos.token == token, "TokenMismatch");
        require(pos.aTokenShares > 0, "NoPosition");

        // Withdraw only our position's aToken shares — not the global balance
        address aToken = _getAToken(token);
        uint256 currentATokenBalance = IERC20(aToken).balanceOf(address(this));
        // pos.aTokenShares was recorded as the rebased-balance delta at deposit time.
        // Since the liquidity index equals INITIAL_INDEX at deposit, aTokenShares == scaled shares.
        // Current underlying value = scaledShares * currentLiquidityIndex / INITIAL_INDEX.
        // We retrieve currentIndex from the pool to compute the correct withdrawal amount,
        // which correctly includes any yield that has accrued since deposit.
        uint256 currentIndex = aavePool.getReserveNormalizedIncome(token);
        uint256 positionCurrentValue = (pos.aTokenShares * currentIndex) / 1e27;
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
        uint256 principal = pos.principalDeposited;
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
        YieldPosition memory pos = positions[msg.sender][escrowId];
        require(pos.token == token, "TokenMismatch");

        address aToken = _getAToken(token);
        uint256 currentATokenBalance = IERC20(aToken).balanceOf(address(this));

        uint256 currentIndex = aavePool.getReserveNormalizedIncome(token);
        uint256 positionCurrentValue = (pos.aTokenShares * currentIndex) / 1e27;
        uint256 sharesToWithdraw = positionCurrentValue <= currentATokenBalance
            ? positionCurrentValue
            : currentATokenBalance;


        if (sharesToWithdraw == 0) {
            revert("NoATokenBalance");
        }

        // Try to withdraw
        uint256 out = aavePool.withdraw(token, sharesToWithdraw, address(this));

        // Transfer to escrow
        IERC20(token).safeTransfer(msg.sender, out);

        // Clean up
        delete positions[msg.sender][escrowId];

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

    // ============ Helpers ============

    /**
     * @notice Get aToken address for underlying token, reverts if not configured
     */
    function _getAToken(address token) internal view returns (address aToken) {
        aToken = tokenToAToken[token];
        if (aToken == address(0)) revert TokenNotConfigured(token);
    }
}
