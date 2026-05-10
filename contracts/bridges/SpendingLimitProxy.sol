// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './DeferredFundingBridge.sol';

/**
 * @title SpendingLimitProxy
 * @notice Enforces per-delegate spending caps on DeferredFundingBridge escrow payments.
 *
 * Problem solved
 * --------------
 * The bridge releaser must hold tokens. If that wallet (agent, hot wallet, employee device)
 * is compromised the attacker can drain everything. This contract inverts that risk:
 * the OWNER (cold wallet / multisig) deposits tokens and the DELEGATE (hot wallet / agent)
 * is granted a bounded spending policy. The delegate holds zero tokens — compromise of
 * the delegate key exposes at most the remaining daily cap.
 *
 * Two funding paths
 * -----------------
 * A. fundEscrow()                — proxy funds and creates escrow only; no creator
 *                                  signature required (proxy is `from` in the vault escrow).
 * B. fundFromCreatorSignature()  — proxy funds an off-chain EIP-712 commitment signed by a
 *                                  creator; proxy is the bridge releaser.
 *
 * Policy model
 * ------------
 * Each (delegate, token) pair has an independent Policy:
 *   maxPerTx      — single-transaction ceiling
 *   dailyLimit    — rolling 24-hour aggregate cap
 *   monthlyLimit  — rolling 30-day aggregate cap
 *   maxTxPerHour  — rate limit; anti-splitting defence
 *
 * token = address(0) is a wildcard matching any token not explicitly registered.
 * Wildcard policies share the same limit values but windows are tracked independently
 * per actual token, so "1 000 / day" applies to 1 000 USDC/day AND 1 000 USDT/day.
 *
 * Rolling windows (not calendar days) close the midnight-reset exploit.
 *
 * Limit increases
 * ---------------
 * Increasing any limit requires a 24-hour timelock queue (queuePolicyIncrease →
 * executePolicyIncrease). Decreases, revocation, and pausing are always instant.
 * This bounds the damage from a brief cold-wallet compromise.
 *
 * Ownership
 * ---------
 * Two-step ownership transfer (transferOwnership → acceptOwnership) prevents
 * accidental loss of control.
 */
contract SpendingLimitProxy is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Immutable ─────────────────────────────────────────────────────────────

    /// @notice The bridge this proxy delegates Path-B commitments to
    DeferredFundingBridge public immutable bridge;

    /// @notice The vault this proxy uses for Path-A direct escrow creation
    IEscrowVaultMinimal public immutable vault;

    // ─── Ownership ─────────────────────────────────────────────────────────────

    address public owner;
    address public pendingOwner;

    // ─── Constants ─────────────────────────────────────────────────────────────

    uint256 public constant INCREASE_TIMELOCK = 24 hours;

    uint256 private constant _1H  = 1 hours;
    uint256 private constant _24H = 24 hours;
    uint256 private constant _30D = 30 days;

    // ─── Data structures ───────────────────────────────────────────────────────

    /**
     * @dev Spending policy for a (delegate, token) pair.
     *      Set any numeric field to type(uint128).max / type(uint32).max for "unlimited".
     *      token = address(0) acts as a wildcard (applies to any unregistered token).
     */
    struct Policy {
        uint128 maxPerTx;       // max single-transaction amount (native token units)
        uint128 dailyLimit;     // max total in any rolling 24-hour window
        uint128 monthlyLimit;   // max total in any rolling 30-day window
        uint32  maxTxPerHour;   // max transactions in any rolling 1-hour window
        bool    active;         // false = policy disabled (delegate cannot spend this token)
    }

    /**
     * @dev Rolling usage windows for a (delegate, token) pair.
     *      Keyed by actual token address even when a wildcard policy applies, so each
     *      token has its own independent counters.
     *
     *      Storage layout: two slots.
     *        Slot 1: dailySpent (128) | monthlySpent (128)
     *        Slot 2: txThisHour (32) | dailyWindowStart (48) | monthlyWindowStart (48) |
     *                hourWindowStart (48) | [16 bits padding]
     */
    struct Window {
        uint128 dailySpent;
        uint128 monthlySpent;
        uint32  txThisHour;
        uint48  dailyWindowStart;
        uint48  monthlyWindowStart;
        uint48  hourWindowStart;
    }

    /**
     * @dev A queued limit increase awaiting the 24-hour timelock.
     */
    struct PendingIncrease {
        Policy  newPolicy;
        uint128 readyAt;    // block.timestamp + INCREASE_TIMELOCK at queue time
        bool    exists;
    }

    // ─── Storage ───────────────────────────────────────────────────────────────

    /// @notice delegate → token → Policy  (token = address(0) is the wildcard slot)
    mapping(address => mapping(address => Policy)) public policies;

    /// @notice delegate → token → Window  (always keyed by actual token, never address(0))
    mapping(address => mapping(address => Window)) internal _windows;

    /// @notice delegate → token → queued increase
    mapping(address => mapping(address => PendingIncrease)) public pendingIncreases;

    /// @notice delegate → globally paused (instant emergency override)
    mapping(address => bool) public delegatePaused;

    // ─── Errors ────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotPendingOwner();
    error ZeroBridgeAddress();
    error ZeroOwnerAddress();
    error ZeroToken();
    error ZeroRecipient();
    error ZeroAmount();
    error DelegatePausedError(address delegate);
    error PolicyNotActive(address delegate, address token);
    error ExceedsPerTxLimit(uint256 requested, uint256 maxPerTx);
    error ExceedsDaily(uint256 requested, uint256 available);
    error ExceedsMonthly(uint256 requested, uint256 available);
    error ExceedsRateLimit(uint32 txThisHour, uint32 maxTxPerHour);
    error InsufficientProxyBalance(address token, uint256 requested, uint256 available);
    error TimelockNotExpired(uint256 readyAt, uint256 currentTime);
    error NoPendingIncrease(address delegate, address token);
    error MustUsePolicyIncreaseQueue();

    // ─── Events ────────────────────────────────────────────────────────────────

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event Deposited(address indexed token, uint256 amount);
    event Withdrawn(address indexed token, uint256 amount, address indexed to);

    event PolicyGranted(address indexed delegate, address indexed token, Policy policy);
    event PolicyRevoked(address indexed delegate, address indexed token);
    event DelegatePaused(address indexed delegate);
    event DelegateUnpaused(address indexed delegate);

    event PolicyIncreaseQueued(
        address indexed delegate,
        address indexed token,
        Policy newPolicy,
        uint256 readyAt
    );
    event PolicyIncreaseExecuted(address indexed delegate, address indexed token, Policy newPolicy);
    event PolicyIncreaseCancelled(address indexed delegate, address indexed token);

    event SpendRecorded(
        address indexed delegate,
        address indexed token,
        uint256 amount,
        uint256 dailyTotal,
        uint256 dailyLimit,
        uint256 monthlyTotal,
        uint256 monthlyLimit
    );

    event EscrowFunded(
        address indexed delegate,
        address indexed token,
        address indexed recipient,
        uint256 grossAmount,
        uint256 vaultWorkflowId   // 0 for Path B (workflowId not returned by bridge)
    );

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param bridgeAddress  DeferredFundingBridge to delegate to
     * @param initialOwner   Cold wallet / multisig that manages policies and funds
     */
    constructor(address bridgeAddress, address initialOwner) {
        if (bridgeAddress == address(0)) revert ZeroBridgeAddress();
        if (initialOwner  == address(0)) revert ZeroOwnerAddress();
        bridge = DeferredFundingBridge(bridgeAddress);
        vault  = bridge.vault();
        owner  = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OWNERSHIP
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initiate a two-step ownership transfer. New owner must call acceptOwnership().
     */
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /**
     * @notice Complete the ownership transfer. Must be called by the pending owner.
     */
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = pendingOwner;
        delete pendingOwner;
        emit OwnershipTransferred(previous, owner);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUNDING MANAGEMENT (owner only)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit tokens from the owner's wallet into this proxy.
     * @dev Owner must approve this contract before calling.
     */
    function deposit(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, amount);
    }

    /**
     * @notice Withdraw tokens from this proxy. Only callable by the owner.
     * @param token  ERC20 token address
     * @param amount Amount to withdraw
     * @param to     Destination address
     */
    function withdraw(address token, uint256 amount, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, amount, to);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POLICY MANAGEMENT (owner only)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new policy or decrease limits on an existing one.
     *
     *         To INCREASE any limit on an existing policy, use queuePolicyIncrease()
     *         instead — this enforces the 24-hour timelock.
     *
     *         Initial grants (no existing active policy) are always immediate.
     *
     * @param delegate  Hot wallet / agent / employee address
     * @param token     ERC20 token (address(0) = wildcard for any unregistered token)
     * @param policy    New policy struct; `active` must be true to enable the delegate
     */
    function grantPolicy(
        address delegate,
        address token,
        Policy calldata policy
    ) external onlyOwner {
        Policy memory existing = policies[delegate][token];
        if (existing.active && _isAnyIncrease(existing, policy)) {
            revert MustUsePolicyIncreaseQueue();
        }
        policies[delegate][token] = policy;
        emit PolicyGranted(delegate, token, policy);
    }

    /**
     * @notice Immediately remove a delegate's policy for a token (or the wildcard).
     */
    function revokePolicy(address delegate, address token) external onlyOwner {
        delete policies[delegate][token];
        emit PolicyRevoked(delegate, token);
    }

    /**
     * @notice Instantly freeze all spending for a delegate across all tokens.
     */
    function pauseDelegate(address delegate) external onlyOwner {
        delegatePaused[delegate] = true;
        emit DelegatePaused(delegate);
    }

    /**
     * @notice Restore a paused delegate.
     */
    function unpauseDelegate(address delegate) external onlyOwner {
        delegatePaused[delegate] = false;
        emit DelegateUnpaused(delegate);
    }

    /**
     * @notice Queue a policy change that increases one or more limits.
     *         The increase becomes executable after INCREASE_TIMELOCK (24 hours).
     *
     * @dev    Any policy change (even mixed increase+decrease) must go through the queue
     *         if any limit is being raised. Use grantPolicy for pure decreases.
     */
    function queuePolicyIncrease(
        address delegate,
        address token,
        Policy calldata newPolicy
    ) external onlyOwner {
        uint128 readyAt = uint128(block.timestamp + INCREASE_TIMELOCK);
        pendingIncreases[delegate][token] = PendingIncrease({
            newPolicy: newPolicy,
            readyAt: readyAt,
            exists: true
        });
        emit PolicyIncreaseQueued(delegate, token, newPolicy, readyAt);
    }

    /**
     * @notice Apply a queued policy increase after the timelock has expired.
     */
    function executePolicyIncrease(address delegate, address token) external onlyOwner {
        PendingIncrease memory pi = pendingIncreases[delegate][token];
        if (!pi.exists) revert NoPendingIncrease(delegate, token);
        if (block.timestamp < pi.readyAt) revert TimelockNotExpired(pi.readyAt, block.timestamp);
        delete pendingIncreases[delegate][token];
        policies[delegate][token] = pi.newPolicy;
        emit PolicyIncreaseExecuted(delegate, token, pi.newPolicy);
    }

    /**
     * @notice Cancel a queued policy increase before it executes.
     */
    function cancelPolicyIncrease(address delegate, address token) external onlyOwner {
        if (!pendingIncreases[delegate][token].exists) revert NoPendingIncrease(delegate, token);
        delete pendingIncreases[delegate][token];
        emit PolicyIncreaseCancelled(delegate, token);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DELEGATE ACTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
 * @notice PATH A — Fund and create an escrow directly through the vault.
     *
 *         The proxy creates the escrow (proxy = `from`) and leaves it in normal
 *         protected lifecycle (PENDING until explicit release/cancel/dispute flow).
 *         No creator signature is needed: the delegate is authorised by policy.
     *
     * @param token      ERC20 token held by this proxy
     * @param recipient  Escrow beneficiary
     * @param amount     Gross amount; vault fee is deducted internally
     * @param settings   Escrow settings (resolver, yield preset, auto-release/cancel times)
     * @return workflowId  Vault escrow identifier
     */
    function fundEscrow(
        address token,
        address recipient,
        uint256 amount,
        EscrowSettings calldata settings
    ) external nonReentrant returns (uint256 workflowId) {
        if (token     == address(0)) revert ZeroToken();
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount    == 0)          revert ZeroAmount();

        _checkAndUpdateLimits(msg.sender, token, amount);
        _checkProxyBalance(token, amount);

        // Approve vault for exactly this amount; reset after creation (CEI-safe)
        IERC20(token).forceApprove(address(vault), amount);
        workflowId = vault.createEscrow(token, recipient, amount, settings);
        IERC20(token).forceApprove(address(vault), 0);

        emit EscrowFunded(msg.sender, token, recipient, amount, workflowId);
    }

    /**
     * @notice PATH B — Fund an escrow on behalf of a creator who signed an off-chain
     *         EIP-712 DeferredCommitment. The proxy is the bridge releaser and provides
     *         funds; the creator never needs to hold tokens or send a transaction.
     *
     * @param token      ERC20 token held by this proxy
     * @param recipient  Escrow beneficiary
     * @param amount     Gross amount
     * @param nonce      Creator-chosen nonce (prevents replay)
     * @param deadline   Commitment expiry timestamp
     * @param creatorSig EIP-712 signature from the creator's wallet
     */
    function fundFromCreatorSignature(
        address token,
        address recipient,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata creatorSig
    ) external nonReentrant {
        if (token     == address(0)) revert ZeroToken();
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount    == 0)          revert ZeroAmount();

        _checkAndUpdateLimits(msg.sender, token, amount);
        _checkProxyBalance(token, amount);

        // Approve bridge to pull funds from this proxy (proxy = releaser in the sig)
        IERC20(token).forceApprove(address(bridge), amount);
        bridge.executeFromSignature(token, recipient, address(this), amount, nonce, deadline, creatorSig);
        // bridge.executeFromSignature consumed the full allowance; reset defensively
        IERC20(token).forceApprove(address(bridge), 0);

        // workflowId not returned by bridge; correlate via CommitmentExecuted event
        emit EscrowFunded(msg.sender, token, recipient, amount, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve the effective policy for a delegate/token pair,
     *         falling back to the wildcard (address(0)) if no specific policy exists.
     */
    function getPolicy(address delegate, address token) external view returns (Policy memory) {
        return _resolvePolicy(delegate, token);
    }

    /// @notice Remaining daily allowance for a delegate/token (accounts for rolling reset)
    function getRemainingDaily(address delegate, address token) external view returns (uint256) {
        Policy memory p = _resolvePolicy(delegate, token);
        if (!p.active) return 0;
        Window memory w = _windows[delegate][token];
        if (block.timestamp - w.dailyWindowStart >= _24H) return p.dailyLimit;
        return p.dailyLimit > w.dailySpent ? p.dailyLimit - w.dailySpent : 0;
    }

    /// @notice Remaining monthly allowance for a delegate/token
    function getRemainingMonthly(address delegate, address token) external view returns (uint256) {
        Policy memory p = _resolvePolicy(delegate, token);
        if (!p.active) return 0;
        Window memory w = _windows[delegate][token];
        if (block.timestamp - w.monthlyWindowStart >= _30D) return p.monthlyLimit;
        return p.monthlyLimit > w.monthlySpent ? p.monthlyLimit - w.monthlySpent : 0;
    }

    /// @notice Remaining transaction count this hour for a delegate/token
    function getRemainingTxThisHour(address delegate, address token) external view returns (uint256) {
        Policy memory p = _resolvePolicy(delegate, token);
        if (!p.active) return 0;
        Window memory w = _windows[delegate][token];
        if (block.timestamp - w.hourWindowStart >= _1H) return p.maxTxPerHour;
        return p.maxTxPerHour > w.txThisHour ? p.maxTxPerHour - w.txThisHour : 0;
    }

    /// @notice Raw window storage for a delegate/token
    function getWindow(address delegate, address token) external view returns (Window memory) {
        return _windows[delegate][token];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _resolvePolicy(address delegate, address token) internal view returns (Policy memory) {
        Policy memory p = policies[delegate][token];
        if (p.active) return p;
        return policies[delegate][address(0)]; // wildcard fallback
    }

    function _checkProxyBalance(address token, uint256 amount) internal view {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < amount) revert InsufficientProxyBalance(token, amount, bal);
    }

    /**
     * @dev Validate and record a spend against the delegate's policy windows.
     *      Reverts on any limit violation. Emits SpendRecorded on success.
     *
     *      Order of checks:
     *        1. Delegate not paused
     *        2. Active policy exists (specific or wildcard)
     *        3. Per-tx limit
     *        4. Rate limit (txThisHour) — checked after window refresh
     *        5. Daily remaining
     *        6. Monthly remaining
     *
     *      Windows are refreshed (rolling reset) before checks so stale
     *      counters from an expired window never block legitimate spends.
     */
    function _checkAndUpdateLimits(address delegate, address token, uint256 amount) internal {
        if (delegatePaused[delegate]) revert DelegatePausedError(delegate);

        Policy memory p = _resolvePolicy(delegate, token);
        if (!p.active) revert PolicyNotActive(delegate, token);

        // Per-tx: amount is uint256 but bounded to uint128 by maxPerTx check
        if (amount > p.maxPerTx) revert ExceedsPerTxLimit(amount, p.maxPerTx);

        // Windows are keyed by actual token (not address(0)) even for wildcard policies
        Window storage w = _windows[delegate][token];
        _refreshWindow(w);

        // Rate limit
        if (w.txThisHour >= p.maxTxPerHour) revert ExceedsRateLimit(w.txThisHour, p.maxTxPerHour);

        // Daily: amount <= maxPerTx <= uint128.max, so newDaily can't overflow uint256
        uint256 newDaily = uint256(w.dailySpent) + amount;
        if (newDaily > p.dailyLimit) {
            uint256 available = w.dailySpent < p.dailyLimit ? p.dailyLimit - w.dailySpent : 0;
            revert ExceedsDaily(amount, available);
        }

        // Monthly
        uint256 newMonthly = uint256(w.monthlySpent) + amount;
        if (newMonthly > p.monthlyLimit) {
            uint256 available = w.monthlySpent < p.monthlyLimit ? p.monthlyLimit - w.monthlySpent : 0;
            revert ExceedsMonthly(amount, available);
        }

        // Commit
        w.dailySpent   = uint128(newDaily);
        w.monthlySpent = uint128(newMonthly);
        w.txThisHour  += 1;

        emit SpendRecorded(delegate, token, amount, newDaily, p.dailyLimit, newMonthly, p.monthlyLimit);
    }

    /**
     * @dev Reset expired rolling windows in-place. A window is expired when
     *      block.timestamp has advanced past its start + duration.
     *
     *      The first-use case (windowStart == 0) is implicitly handled: since
     *      block.timestamp is always >> any duration (Unix epoch >> 30d), the
     *      condition `block.timestamp - 0 >= duration` is always true, so the
     *      window initialises on first spend.
     */
    function _refreshWindow(Window storage w) internal {
        uint256 now_ = block.timestamp;
        if (now_ - w.hourWindowStart >= _1H) {
            w.txThisHour      = 0;
            w.hourWindowStart = uint48(now_);
        }
        if (now_ - w.dailyWindowStart >= _24H) {
            w.dailySpent       = 0;
            w.dailyWindowStart = uint48(now_);
        }
        if (now_ - w.monthlyWindowStart >= _30D) {
            w.monthlySpent       = 0;
            w.monthlyWindowStart = uint48(now_);
        }
    }

    /**
     * @dev Returns true if any numeric limit in `proposed` exceeds the corresponding
     *      limit in `existing`. Used to gate grantPolicy vs queuePolicyIncrease.
     */
    function _isAnyIncrease(Policy memory existing, Policy memory proposed) internal pure returns (bool) {
        return proposed.maxPerTx     > existing.maxPerTx
            || proposed.dailyLimit   > existing.dailyLimit
            || proposed.monthlyLimit > existing.monthlyLimit
            || proposed.maxTxPerHour > existing.maxTxPerHour;
    }

    // ─── ETH rejection ─────────────────────────────────────────────────────────

    receive() external payable {
        revert('SpendingLimitProxy: ETH not accepted');
    }
}
