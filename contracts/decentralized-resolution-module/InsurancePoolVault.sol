// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './ISlashingModule.sol';

/**
 * @title InsurancePoolVault
 * @notice Vault contract holding slashed funds with source tags and governance controls
 * @dev Phase 5.1: Minimal, launch-safe insurance pool implementation
 *
 * Key Features:
 * - Source tags: timeout vs fraud vs reversal (for accounting)
 * - Automatic deposits from slashing module
 * - Withdrawals gated by slow lane + timelock (disabled by default)
 * - Events: InsuranceFunded, InsurancePayoutProposed, InsurancePayoutExecuted
 */
contract InsurancePoolVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_SLASHING_MODULE = keccak256('ROLE_SLASHING_MODULE');

    uint256 public constant SLOW_DELAY = 7 days;

    // ============ State Variables ============

    IERC20 public stableToken;

    // Source-tagged accounting
    struct SourceBalance {
        uint256 timeout; // From timeout slashes
        uint256 reversal; // From reversal slashes
        uint256 fraud; // From fraud slashes
        uint256 total; // Total across all sources
    }
    SourceBalance public sourceBalance;

    // Pending payout proposals (slow lane governance)
    struct PendingPayout {
        address to;
        uint256 amount;
        uint256 workflowId;
        string reason;
        uint64 eta;
        bool exists;
    }
    mapping(uint256 => PendingPayout) public pendingPayouts;
    uint256 private _nextPayoutId;

    // Withdrawal controls
    bool public withdrawalsEnabled;

    // ============ Events ============

    event InsuranceFunded(
        uint256 indexed amount,
        ISlashingModule.SlashReason indexed source,
        uint256 indexed escrowId,
        uint256 newTotalBalance
    );

    event InsurancePayoutProposed(
        uint256 indexed payoutId,
        address indexed to,
        uint256 amount,
        uint256 indexed escrowId,
        string reason,
        uint64 eta
    );

    event InsurancePayoutExecuted(
        uint256 indexed payoutId,
        address indexed to,
        uint256 amount,
        uint256 indexed escrowId
    );

    event WithdrawalsEnabled(bool enabled);

    event PayoutCancelled(uint256 indexed payoutId);

    // ============ Modifiers ============

    modifier onlySlashingModule() {
        require(hasRole(ROLE_SLASHING_MODULE, msg.sender), 'Not slashing module');
        _;
    }

    modifier onlyTimelock() {
        require(hasRole(ROLE_TIMELOCK, msg.sender), 'Not timelock');
        _;
    }

    // ============ Initialization ============

    /**
     * @notice Constructor for immutable insurance pool vault
     * @param initialOwner Initial admin address
     * @param _stableToken Stable token address (USDC, etc.)
     */
    constructor(address initialOwner, address _stableToken) {
        require(_stableToken != address(0), 'Zero token');

        // OpenZeppelin best practice: Grant DEFAULT_ADMIN_ROLE to deployer
        // Deployment scripts will transfer this to TimelockController
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

        stableToken = IERC20(_stableToken);

        withdrawalsEnabled = false; // Disabled by default
    }

    // ============ Core Functions ============

    /**
     * @notice Deposit funds to insurance pool (called by slashing module)
     * @param amount Amount to deposit
     * @param source Source of funds (timeout, reversal, fraud)
     * @param workflowId Related dispute ID (0 if not applicable)
     */
    function deposit(
        uint256 amount,
        ISlashingModule.SlashReason source,
        uint256 workflowId
    ) external onlySlashingModule nonReentrant {
        require(amount > 0, 'Zero amount');

        // Transfer tokens from slashing module
        stableToken.safeTransferFrom(msg.sender, address(this), amount);

        _recordDeposit(amount, source, workflowId);
    }

    /**
     * @notice Record deposit after direct transfer (for cases where funds already transferred)
     * @param amount Amount deposited
     * @param source Source of funds
     * @param workflowId Related dispute ID
     */
    function recordDeposit(
        uint256 amount,
        ISlashingModule.SlashReason source,
        uint256 workflowId
    ) external onlySlashingModule nonReentrant {
        require(amount > 0, 'Zero amount');
        _recordDeposit(amount, source, workflowId);
    }

    /**
     * @notice Internal function to record deposit
     */
    function _recordDeposit(
        uint256 amount,
        ISlashingModule.SlashReason source,
        uint256 workflowId
    ) internal {
        // Update source-tagged accounting
        if (
            source == ISlashingModule.SlashReason.TIMEOUT_ACCEPT ||
            source == ISlashingModule.SlashReason.TIMEOUT_RESOLVE
        ) {
            sourceBalance.timeout += amount;
        } else if (source == ISlashingModule.SlashReason.REVERSAL) {
            sourceBalance.reversal += amount;
        } else if (
            source == ISlashingModule.SlashReason.FRAUD ||
            source == ISlashingModule.SlashReason.COLLUSION ||
            source == ISlashingModule.SlashReason.BRIBERY
        ) {
            sourceBalance.fraud += amount;
        }

        sourceBalance.total += amount;

        emit InsuranceFunded(amount, source, workflowId, sourceBalance.total);
    }

    /**
     * @notice Propose insurance payout (slow lane governance)
     * @param to Recipient address
     * @param amount Amount to payout
     * @param workflowId Related dispute ID
     * @param reason Reason for payout
     * @return payoutId Pending payout ID
     */
    function proposePayout(
        address to,
        uint256 amount,
        uint256 workflowId,
        string memory reason
    ) external onlyTimelock returns (uint256 payoutId) {
        require(to != address(0), 'Zero address');
        require(amount > 0, 'Zero amount');
        require(sourceBalance.total >= amount, 'Insufficient balance');

        payoutId = _nextPayoutId++;

        pendingPayouts[payoutId] = PendingPayout({
            to: to,
            amount: amount,
            workflowId: workflowId,
            reason: reason,
            eta: uint64(block.timestamp + SLOW_DELAY),
            exists: true
        });

        emit InsurancePayoutProposed(
            payoutId,
            to,
            amount,
            workflowId,
            reason,
            pendingPayouts[payoutId].eta
        );

        return payoutId;
    }

    /**
     * @notice Execute pending payout (after slow lane delay)
     * @param payoutId Pending payout ID
     */
    function executePayout(uint256 payoutId) external onlyTimelock nonReentrant {
        PendingPayout storage payout = pendingPayouts[payoutId];
        require(payout.exists, 'Payout not found');
        require(block.timestamp >= payout.eta, 'Delay not passed');
        require(sourceBalance.total >= payout.amount, 'Insufficient balance');

        // Mark as executed
        address to = payout.to;
        uint256 amount = payout.amount;
        uint256 workflowId = payout.workflowId;

        delete pendingPayouts[payoutId];

        // Update balances (proportional reduction across sources)
        _reduceBalances(amount);

        // Transfer tokens
        stableToken.safeTransfer(to, amount);

        emit InsurancePayoutExecuted(payoutId, to, amount, workflowId);
    }

    /**
     * @notice Cancel pending payout
     * @param payoutId Pending payout ID
     */
    function cancelPayout(uint256 payoutId) external onlyTimelock {
        PendingPayout storage payout = pendingPayouts[payoutId];
        require(payout.exists, 'Payout not found');

        delete pendingPayouts[payoutId];

        emit PayoutCancelled(payoutId);
    }

    /**
     * @notice Enable/disable direct withdrawals (emergency control)
     * @param enabled Whether withdrawals are enabled
     */
    function setWithdrawalsEnabled(bool enabled) external onlyRole(ROLE_TIMELOCK) {
        withdrawalsEnabled = enabled;
        emit WithdrawalsEnabled(enabled);
    }

    /**
     * @notice Direct withdrawal (only if enabled, requires timelock)
     * @param to Recipient address
     * @param amount Amount to withdraw
     * @param workflowId Related dispute ID
     */
    function withdraw(
        address to,
        uint256 amount,
        uint256 workflowId
    ) external onlyTimelock nonReentrant {
        require(withdrawalsEnabled, 'Withdrawals disabled');
        require(to != address(0), 'Zero address');
        require(amount > 0, 'Zero amount');
        require(sourceBalance.total >= amount, 'Insufficient balance');

        // Update balances
        _reduceBalances(amount);

        // Transfer tokens
        stableToken.safeTransfer(to, amount);

        emit InsurancePayoutExecuted(0, to, amount, workflowId); // payoutId = 0 for direct withdrawals
    }

    // ============ Internal Functions ============

    /**
     * @notice Reduce balances proportionally across sources
     * @param amount Amount to reduce
     */
    function _reduceBalances(uint256 amount) internal {
        require(amount <= sourceBalance.total, 'Amount exceeds total');

        if (sourceBalance.total > 0) {
            // Proportional reduction
            uint256 timeoutReduction = (sourceBalance.timeout * amount) / sourceBalance.total;
            uint256 reversalReduction = (sourceBalance.reversal * amount) / sourceBalance.total;
            uint256 fraudReduction = amount - timeoutReduction - reversalReduction;

            // Clamp to available balances
            if (timeoutReduction > sourceBalance.timeout) {
                timeoutReduction = sourceBalance.timeout;
            }
            if (reversalReduction > sourceBalance.reversal) {
                reversalReduction = sourceBalance.reversal;
            }
            if (fraudReduction > sourceBalance.fraud) {
                fraudReduction = sourceBalance.fraud;
            }

            // Adjust if rounding causes mismatch
            uint256 totalReduction = timeoutReduction + reversalReduction + fraudReduction;
            if (totalReduction < amount) {
                uint256 remainder = amount - totalReduction;
                if (sourceBalance.fraud >= remainder) {
                    fraudReduction += remainder;
                } else if (sourceBalance.reversal >= remainder) {
                    reversalReduction += remainder;
                } else {
                    timeoutReduction += remainder;
                }
            }

            sourceBalance.timeout -= timeoutReduction;
            sourceBalance.reversal -= reversalReduction;
            sourceBalance.fraud -= fraudReduction;
        }

        sourceBalance.total -= amount;
    }

    // ============ Query Functions ============

    /**
     * @notice Get total balance
     * @return total Total balance
     */
    function getTotalBalance() external view returns (uint256 total) {
        return sourceBalance.total;
    }

    /**
     * @notice Get source-tagged balances
     * @return timeout Balance from timeout slashes
     * @return reversal Balance from reversal slashes
     * @return fraud Balance from fraud slashes
     * @return total Total balance
     */
    function getSourceBalances()
        external
        view
        returns (uint256 timeout, uint256 reversal, uint256 fraud, uint256 total)
    {
        return (
            sourceBalance.timeout,
            sourceBalance.reversal,
            sourceBalance.fraud,
            sourceBalance.total
        );
    }

    /**
     * @notice Get pending payout
     * @param payoutId Payout ID
     * @return to Recipient address
     * @return amount Amount
     * @return workflowId Related dispute ID
     * @return reason Reason for payout
     * @return eta Execution timestamp
     * @return exists Whether payout exists
     */
    function getPendingPayout(
        uint256 payoutId
    )
        external
        view
        returns (
            address to,
            uint256 amount,
            uint256 workflowId,
            string memory reason,
            uint64 eta,
            bool exists
        )
    {
        PendingPayout storage payout = pendingPayouts[payoutId];
        return (
            payout.to,
            payout.amount,
            payout.workflowId,
            payout.reason,
            payout.eta,
            payout.exists
        );
    }

    /**
     * @notice Check if withdrawals are enabled
     * @return enabled Whether withdrawals are enabled
     */
    function isWithdrawalsEnabled() external view returns (bool enabled) {
        return withdrawalsEnabled;
    }

    // ============ UUPS Upgrade ============
}
