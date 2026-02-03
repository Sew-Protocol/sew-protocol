// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldGenerationModule.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '../governance/SlowLaneQueueActivate.sol';
import '../types/EscrowTypes.sol';
import '../interfaces/aave/AaveV3Interfaces.sol';

// Custom errors
error TokenNotSupportedByAave(address token);
error InvalidATokenAddress(address token, address aToken);
// InvalidAddress and ArrayLengthMismatch imported from EscrowTypes.sol
error AaveWithdrawalFailed(uint256 workflowId, address token);
error InsufficientWithdrawalAmount(uint256 actualAmount, uint256 minimumAmount);
error CapExceeded(address token, uint256 requested, uint256 cap);
error InvalidPoolAddress(address pool);
error PoolAddressIsNotContract(address pool);
error PoolProviderCallFailed(address provider);
error BatchSizeTooLarge(uint256 batchSize, uint256 maxBatchSize);
error EscrowContractCannotBeZero();
error CapCannotBeRaised(uint256 newCap, uint256 currentCap);
error NotAuthorized(address caller);
error NotImplementedYet();

/**
 * @title AaveYieldGenerationModule
 * @notice Yield generation module implementing Aave V3 integration with ERC-4626 vault standard
 * @dev Implements ERC-4626 for standardized vault semantics while maintaining Aave V3 integration.
 *      Shares are tracked as ERC20 tokens (via ERC4626 base).
 *      Distribution is handled separately by IYieldDistributionModule.
 */
contract AaveYieldGenerationModule is IYieldGenerationModule, ERC4626, AccessControl, SlowLaneQueueActivate {
    // Module-specific errors (scoped to avoid global name collisions)
    error AavePoolNotConfigured();

    // Role constants for governance
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');
    bytes32 public constant ROLE_YIELD_OPS = keccak256('ROLE_YIELD_OPS');
    using SafeERC20 for IERC20;

    // Aave configuration
    IAavePoolAddressesProvider public aavePoolAddressesProvider;
    IAavePool public aavePool;
    bool public aaveEnabled = false;

    // Cap bounds
    /// @notice Maximum cap value (type(uint128).max to prevent overflow)
    uint256 public constant CAP_MAX = type(uint128).max;

    // Token support mapping
    mapping(address => address) public tokenToAToken; // token => aToken address
    mapping(address => uint256) public totalDepositedToAave; // token => total underlying amount
    mapping(address => uint256) public totalScaledBalance; // token => total scaled shares (non-rebasing)
    
    // Aggregate yield tracking (for auditability)
    mapping(address => uint256) public totalYieldGenerated; // token => total yield generated (all time)
    mapping(address => uint256) public totalYieldWithdrawn; // token => total yield withdrawn (all time)

    // Exposure tracking and caps (Phase 4)
    mapping(address => uint256) public tokenCap; // token => maximum exposure per token (DEPRECATED: use globalCap)
    mapping(address => uint256) public globalCap; // token => global maximum exposure (System Safety)
    mapping(address => uint256) public currentExposure; // token => current total exposure

    // Per-escrow fairness caps (Recommendation 1.B)
    mapping(address => mapping(address => uint256)) public escrowCap; // escrowContract => token => maximum exposure (Fairness)
    mapping(address => mapping(address => uint256)) public currentEscrowExposure; // escrowContract => token => current exposure

    // Per-escrow tracking (escrow contract address => workflowId => data)
    mapping(address => mapping(uint256 => bool)) public escrowInAave; // escrowContract => workflowId => is in Aave
    mapping(address => mapping(uint256 => uint256)) public escrowScaledBalance; // escrowContract => workflowId => scaled balance (shares)
    mapping(address => mapping(uint256 => uint256)) public escrowOriginalDeposit; // escrowContract => workflowId => original deposit amount
    
    // ERC-4626 escrow-specific tracking (per-workflow share accounting)
    mapping(address => mapping(uint256 => uint256)) public escrowShares; // escrowContract => workflowId => shares minted
    mapping(address => mapping(uint256 => uint256)) public escrowPrincipal; // escrowContract => workflowId => principal deposited
    
    // Slow lane pending changes (Phase 3)
    PendingAddress private _pendingPoolProvider;

    // Events
    event EscrowDepositedToAave(
        uint256 indexed workflowId,
        address indexed token,
        uint256 amount,
        uint256 aTokenBalance
    );
    event EscrowWithdrawnFromAave(
        uint256 indexed workflowId,
        address indexed token,
        uint256 originalAmount,
        uint256 actualAmount,
        uint256 yield
    );
    event AaveWithdrawalFailedEvent(uint256 indexed workflowId, address indexed token);
    event AavePoolConfigured(address indexed provider, address indexed pool);
    event AaveEnabledUpdated(bool enabled);
    event TokenRegisteredForAave(address indexed token, address indexed aToken);
    event EscrowCapSet(address indexed escrowContract, address indexed token, uint256 oldCap, uint256 newCap);

    error EscrowCapExceeded(address escrowContract, address token, uint256 requested, uint256 cap);

    // Slow lane queue/activate events (Phase 3)
    event AavePoolProviderQueued(
        address indexed oldProvider,
        address indexed newProvider,
        uint64 eta
    );
    event AavePoolProviderActivated(address indexed oldProvider, address indexed newProvider);

    // Guardian emergency control events (Phase 4)
    event AaveDisabledByGuardian();
    event TokenCapLowered(address indexed token, uint256 oldCap, uint256 newCap);
    event GlobalCapLowered(address indexed token, uint256 oldCap, uint256 newCap);
    event TokenCapSet(address indexed token, uint256 oldCap, uint256 newCap);
    event GlobalCapSet(address indexed token, uint256 oldCap, uint256 newCap);
    event ExposureUpdated(address indexed token, uint256 oldExposure, uint256 newExposure);
    event TotalYieldGeneratedUpdated(address indexed token, uint256 totalYieldGenerated);

    // Underlying asset for ERC-4626 (can be any token; module supports multi-token deposits)
    // This is primarily for ERC4626 interface compatibility
    address private _singleUnderlyingAsset;

    // Dust tracking per token
    mapping(address => uint256) public protocolDust;
    // Deficit tracking (negative dust absorbed by protocol)
    mapping(address => uint256) public protocolDeficit;

    // Events
    event DustAccumulated(address indexed token, uint256 amount);
    event DeficitAccumulated(address indexed token, uint256 amount);
    event DustSwept(address indexed token, address indexed recipient, uint256 amount);

    /**
     * @notice Constructor
     * @param initialOwner Initial admin address
     */
    constructor(address initialOwner) 
        ERC4626(IERC20(address(0)))
        ERC20("Aave Yield Shares", "AAVE-SHARES") {
        _singleUnderlyingAsset = address(0);
        // Grant DEFAULT_ADMIN_ROLE to initialOwner so roles can be granted later
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    /**
     * @notice Deposit funds to Aave for yield generation
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param amount Amount to deposit
     * @return success True if deposit was successful
     * @return yieldTokenBalance Balance of aToken received
     * @dev Called by BaseEscrow when creating an escrow with yieldEnabled=true
     */
    function depositForYield(
        uint256 workflowId,
        address token,
        uint256 amount,
        address escrowContract
    ) external override returns (bool success, uint256 yieldTokenBalance) {
        // MED-3: Zero address check for escrow contract
        if (escrowContract == address(0)) revert EscrowContractCannotBeZero();
        
        // HIGH-1: Authorization check
        if (!hasRole(ROLE_ESCROW_CONTRACT, _msgSender()) && !hasRole(ROLE_YIELD_OPS, _msgSender())) {
            revert NotAuthorized(_msgSender());
        }
        
        // Verify escrowContract is the caller, OR caller is a trusted Ops contract
        if (_msgSender() != escrowContract && !hasRole(ROLE_YIELD_OPS, _msgSender())) {
            revert NotAuthorized(escrowContract);
        }

        // Check if Aave is enabled
        if (!aaveEnabled) {
            return (true, 0); // Aave not enabled, skip deposit (not an error)
        }

        // Validate token is supported by Aave
        address aToken = tokenToAToken[token];
        if (aToken == address(0)) {
            return (true, 0); // Token not supported, skip deposit (not an error)
        }

        // Validate Aave Pool is configured
        if (address(aavePool) == address(0)) {
            revert AavePoolNotConfigured();
        }

        // Check and accrue exposure (Phase 4)
        _checkAndAccrueExposure(escrowContract, token, amount);

        // Track aggregate principal deposited (Phase 4)
        // 1. EscrowVault: Escrow contract approved this module, module pulls tokens and supplies to pool
        // 2. EscrowableERC20: Escrow contract IS the token, it approves pool directly, module just calls pool.supply
        // Check if escrow contract approved this module (for EscrowVault)
        uint256 moduleAllowance = IERC20(token).allowance(escrowContract, address(this));
        bool pulledTokens = false;
        
        if (moduleAllowance >= amount) {
            // EscrowVault case: Pull tokens from escrow contract
            IERC20(token).safeTransferFrom(escrowContract, address(this), amount);
            pulledTokens = true;
            // Approve pool to spend tokens (module now holds the tokens)
            uint256 currentAllowance = IERC20(token).allowance(address(this), address(aavePool));
            if (currentAllowance < amount) {
                if (currentAllowance > 0) {
                    IERC20(token).safeDecreaseAllowance(address(aavePool), currentAllowance);
                }
                IERC20(token).safeIncreaseAllowance(address(aavePool), amount);
            }
        }
        // Else: EscrowableERC20 case - escrow contract approved pool directly, just call pool.supply
        
        // Get scaled balance before deposit (for tracking the increase in shares)
        uint256 scaledBalanceBefore = IAaveAToken(aToken).scaledBalanceOf(address(this));
        
        // Deposit to Aave (referral code 0 = no referral)
        // We supply on behalf of this module so we can withdraw later
        aavePool.supply(token, amount, address(this), 0);
        
        // Get scaled balance after deposit and calculate the increase in shares for this deposit
        uint256 scaledBalanceAfter = IAaveAToken(aToken).scaledBalanceOf(address(this));
        uint256 mintedShares = scaledBalanceAfter > scaledBalanceBefore ? scaledBalanceAfter - scaledBalanceBefore : 0;
        
        // If scaledBalanceOf is not supported or returns 0 (unlikely for real aToken), 
        // fall back to calculating from amount and liquidity index
        if (mintedShares == 0 && amount > 0) {
            uint256 index = aavePool.getReserveNormalizedIncome(token);
            if (index > 0) {
                mintedShares = (amount * 1e27) / index;
            }
        }
        
        yieldTokenBalance = amount; // Return underlying amount for compatibility

        // Track deposit
        escrowInAave[escrowContract][workflowId] = true;
        escrowScaledBalance[escrowContract][workflowId] += mintedShares;
        escrowOriginalDeposit[escrowContract][workflowId] += amount;
        totalDepositedToAave[token] += amount;
        totalScaledBalance[token] += mintedShares;

        emit EscrowDepositedToAave(workflowId, token, amount, mintedShares);

        return (true, yieldTokenBalance);
    }

    /**
     * @notice Withdraw funds from Aave and calculate yield
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param originalAmount Original deposit amount
     * @return success True if withdrawal was successful
     * @return actualAmount Actual amount withdrawn (including yield)
     * @return yieldAmount Amount of yield generated
     * @dev Called by BaseEscrow when releasing or cancelling an escrow
     */
    function withdrawWithYield(
        uint256 workflowId,
        address token,
        uint256 originalAmount,
        address escrowContract
    ) external override returns (bool success, uint256 actualAmount, uint256 yieldAmount) {
        // HIGH-2: Authorization checks
        if (!hasRole(ROLE_ESCROW_CONTRACT, _msgSender()) && !hasRole(ROLE_YIELD_OPS, _msgSender())) {
            revert NotAuthorized(_msgSender());
        }

        // Verify escrowContract is the caller, OR caller is a trusted Ops contract
        if (_msgSender() != escrowContract && !hasRole(ROLE_YIELD_OPS, _msgSender())) {
            revert NotAuthorized(escrowContract);
        }

        if (escrowContract == address(0)) {
            // No escrow tracked for this workflowId, return original amount
            return (true, originalAmount, 0);
        }

        if (!escrowInAave[escrowContract][workflowId]) {
            return (true, originalAmount, 0); // Not in Aave, return original amount
        }

        address aToken = tokenToAToken[token];
        if (aToken == address(0)) {
            return (true, originalAmount, 0); // Token mapping lost, return original
        }

        uint256 trackedScaledBalance = escrowScaledBalance[escrowContract][workflowId];
        uint256 originalDeposit = escrowOriginalDeposit[escrowContract][workflowId];

        // Get current aToken balance (includes accrued yield)
        uint256 currentATokenBalance = IAaveAToken(aToken).balanceOf(address(this));
        
        // Determine withdrawal amount based on shares (scaled balance)
        uint256 withdrawalAmount;
        if (currentATokenBalance > 0 && trackedScaledBalance > 0) {
            // withdrawalAmount = (Total Aave Balance * Escrow Shares) / Total Shares
            withdrawalAmount = (currentATokenBalance * trackedScaledBalance) / totalScaledBalance[token];
            
            // Ensure we withdraw at least 1 unit if shares exist (prevent rounding to 0)
            if (withdrawalAmount == 0 && trackedScaledBalance > 0) {
                withdrawalAmount = 1;
            }

            if (withdrawalAmount > currentATokenBalance) {
                withdrawalAmount = currentATokenBalance;
            }
        } else {
            // Fallback for cases where scaled balance is zero or not used
            withdrawalAmount = originalDeposit;
        }

        // Fix checks-effects-interactions pattern
        // Withdraw from Aave FIRST (interaction), then clear state (effect)
        // Use low-level call for error handling
        (bool callSuccess, bytes memory returnData) = address(aavePool).call(
            abi.encodeWithSelector(IAavePool.withdraw.selector, token, withdrawalAmount, _msgSender())
        );

        if (!callSuccess) {
            // Aave withdrawal failed - state not yet cleared, so tracking is preserved
            emit AaveWithdrawalFailedEvent(workflowId, token);
            return (false, originalAmount, 0);
        }

        // Decode actual amount withdrawn
        actualAmount = abi.decode(returnData, (uint256));

        // Clear state AFTER successful withdrawal
        escrowInAave[escrowContract][workflowId] = false;
        escrowScaledBalance[escrowContract][workflowId] = 0;
        escrowOriginalDeposit[escrowContract][workflowId] = 0;

        // Update total deposited and total scaled balance
        if (totalDepositedToAave[token] >= originalDeposit) {
            totalDepositedToAave[token] -= originalDeposit;
        }
        if (totalScaledBalance[token] >= trackedScaledBalance) {
            totalScaledBalance[token] -= trackedScaledBalance;
        }

        // Reduce exposure (Phase 4)
        // HIGH-3: Reduce by actual amount to account for losses
        _reduceExposure(escrowContract, token, actualAmount);

        // Dust & Yield Handling
        // Dust is defined as rounding discrepancies <= 5 wei
        uint256 dustThreshold = 5;

        if (actualAmount >= originalDeposit) {
            yieldAmount = actualAmount - originalDeposit;
            // If yield is extremely tiny, it might be dust rather than actual yield
            if (yieldAmount > 0 && yieldAmount <= dustThreshold) {
                protocolDust[token] += yieldAmount;
                emit DustAccumulated(token, yieldAmount);
                yieldAmount = 0;
                actualAmount = originalDeposit;
            }
        } else {
            uint256 shortfall = originalDeposit - actualAmount;
            if (shortfall <= dustThreshold) {
                // Shortfall is within dust bounds. Try to cover with accumulated dust first.
                if (protocolDust[token] >= shortfall) {
                    protocolDust[token] -= shortfall;
                } else {
                    uint256 remainingShortfall = shortfall - protocolDust[token];
                    protocolDust[token] = 0;
                    protocolDeficit[token] += remainingShortfall;
                    emit DeficitAccumulated(token, remainingShortfall);
                }
                actualAmount = originalDeposit;
                yieldAmount = 0;
            } else {
                yieldAmount = 0;
                // Significant loss occurred
            }
        }

        // Update aggregate yield tracking (for auditability)
        if (yieldAmount > 0) {
            totalYieldGenerated[token] += yieldAmount;
            totalYieldWithdrawn[token] += yieldAmount;
            emit TotalYieldGeneratedUpdated(token, totalYieldGenerated[token]);
        }

        emit EscrowWithdrawnFromAave(workflowId, token, originalDeposit, actualAmount, yieldAmount);

        return (true, actualAmount, yieldAmount);
    }

    /**
     * @notice Get consolidated position data for an escrow
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param escrowContract Address of the escrow contract
     * @return position Consolidated position data
     */
    function getPosition(
        uint256 workflowId,
        address token,
        address escrowContract
    ) external view override returns (YieldPosition memory position) {
        position.isActive = escrowInAave[escrowContract][workflowId];
        if (position.isActive) {
            position.scaledShares = escrowScaledBalance[escrowContract][workflowId];
            position.principal = escrowOriginalDeposit[escrowContract][workflowId];
            position.currentYield = this.calculateYield(workflowId, token, escrowContract);
        }
    }

    /**
     * @notice Calculate current yield for an escrow
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param escrowContract Address of the escrow contract
     * @return yieldAmount Current yield amount
     * @dev Calculates yield by comparing current aToken value to original deposit
     */
    function calculateYield(
        uint256 workflowId,
        address token,
        address escrowContract
    ) external view override returns (uint256 yieldAmount) {
        if (!escrowInAave[escrowContract][workflowId]) {
            return 0; // Not in Aave, no yield
        }

        address aToken = tokenToAToken[token];
        if (aToken == address(0)) {
            return 0; // Token not supported
        }

        uint256 currentATokenBalance = IAaveAToken(aToken).balanceOf(address(this));
        uint256 trackedScaledBalance = escrowScaledBalance[escrowContract][workflowId];
        uint256 originalDeposit = escrowOriginalDeposit[escrowContract][workflowId];

        if (trackedScaledBalance == 0 || originalDeposit == 0) {
            return 0; // No tracking data
        }

        // Calculate current value of aTokens using the pool share logic
        // estimatedCurrentValue = (Total Underlying * Escrow Shares) / Total Shares
        uint256 totalScaled = totalScaledBalance[token];
        if (totalScaled == 0) return 0;
        
        uint256 estimatedCurrentValue = (currentATokenBalance * trackedScaledBalance) /
            totalScaled;

        // Yield = estimated current value - original deposit
        if (estimatedCurrentValue > originalDeposit) {
            yieldAmount = estimatedCurrentValue - originalDeposit;
        }

        return yieldAmount;
    }

    /**
     * @notice Get total yield statistics for a token (for financial auditing)
     * @param token Token address
     * @return totalGenerated Total yield generated (all time)
     * @return totalWithdrawn Total yield withdrawn (all time)
     * @return totalDeposited Total deposited to Aave (all time)
     */
    function getYieldStatistics(address token) external view returns (
        uint256 totalGenerated,
        uint256 totalWithdrawn,
        uint256 totalDeposited
    ) {
        return (
            totalYieldGenerated[token],
            totalYieldWithdrawn[token],
            totalDepositedToAave[token]
        );
    }

    /**
     * @notice Check if token is supported for yield generation
     * @param token Token address
     * @return supported True if supported
     */
    function isTokenSupported(address token) external view override returns (bool supported) {
        return aaveEnabled && tokenToAToken[token] != address(0);
    }

    /**
     * @notice Get the approval target address for a token (if escrow contract needs to approve before deposit)
     * @param token Token address
     * @return approvalTarget Address that needs approval (address(0) if no approval needed or handled by module)
     * @dev For EscrowableERC20: returns the Aave pool address that needs approval
     *      For EscrowVault: returns address(0) as module handles approvals via forceApprove
     *      Returns address(0) if Aave is not enabled or token is not supported
     */
    function getApprovalTarget(
        address token
    ) external view override returns (address approvalTarget) {
        if (!aaveEnabled) {
            return address(0);
        }
        if (tokenToAToken[token] == address(0)) {
            return address(0); // Token not supported
        }
        // For EscrowableERC20, the escrow contract needs to approve the Aave pool
        // For EscrowVault, the module handles approvals, so return address(0)
        // We return the pool address - the caller (EscrowableERC20) will handle approval if needed
        return address(aavePool);
    }

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure override returns (string memory name) {
        return 'AaveYieldGeneration';
    }

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning)
     */
    function moduleVersion() external pure override returns (string memory version) {
        return '1.0.0';
    }

    /**
     * @notice Register an authorized escrow contract
     * @param escrow Address of the escrow contract
     */
    function registerEscrowContract(address escrow) external onlyRole(ROLE_TIMELOCK) {
        if (escrow == address(0)) revert InvalidAddress(uint8(ADDR_ESCROW_CONTRACT), escrow);
        _grantRole(ROLE_ESCROW_CONTRACT, escrow);
    }

    /**
     * @notice ERC-165 interface support
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControl, IERC165) returns (bool) {
        return
            interfaceId == type(IYieldGenerationModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ============ Aave Configuration Functions ============

    /**
     * @notice Queue a new Aave Pool Addresses Provider (Slow lane: 7-day delay)
     * @param provider Address of the Aave Pool Addresses Provider
     * @dev After 7 days, call activateAavePoolProvider() to apply the change
     */
    function queueAavePoolProvider(address provider) public onlyRole(ROLE_TIMELOCK) {
        if (provider == address(0)) {
            revert InvalidAddress(uint8(ADDR_PROVIDER), provider);
        }
        _queueAddress(_pendingPoolProvider, provider);
        emit AavePoolProviderQueued(
            address(aavePoolAddressesProvider),
            provider,
            _pendingPoolProvider.eta
        );
    }

    /**
     * @notice Activate the queued Aave Pool Addresses Provider
     * @dev Reverts if no pending change or 7-day delay has not elapsed.
     *      Validates that the provider returns a valid, non-zero pool address that is a contract.
     * @dev Safety validations:
     *      1. Provider must return non-zero pool address
     *      2. Pool address must be a contract (has code)
     *      3. Provider call must succeed (not revert)
     */
    function activateAavePoolProvider() public onlyRole(ROLE_TIMELOCK) {
        address oldProvider = address(aavePoolAddressesProvider);
        address newProvider = _activateAddress(_pendingPoolProvider);

        // Safety validation 1: Provider must be a contract (has code)
        if (newProvider.code.length == 0) {
            revert PoolAddressIsNotContract(newProvider);
        }

        // Safety validation 2: Get pool address with error handling
        address poolAddress;
        try IAavePoolAddressesProvider(newProvider).getPool() returns (address pool) {
            poolAddress = pool;
        } catch {
            revert PoolProviderCallFailed(newProvider);
        }

        // Safety validation 3: Pool address must be non-zero
        if (poolAddress == address(0)) {
            revert InvalidPoolAddress(poolAddress);
        }

        // Safety validation 4: Pool address must be a contract (has code)
        if (poolAddress.code.length == 0) {
            revert PoolAddressIsNotContract(poolAddress);
        }

        // Safety validation 5: Optional - Verify pool implements expected interface
        // Note: Full interface validation is complex and gas-intensive.
        // Governance should verify the pool address is correct before activation.
        // The pool will be validated during first use (depositForYield will fail if invalid).

        // All validations passed - update state (checks-effects-interactions pattern)
        aavePoolAddressesProvider = IAavePoolAddressesProvider(newProvider);
        aavePool = IAavePool(poolAddress);
        aaveEnabled = true;

        emit AavePoolProviderActivated(oldProvider, newProvider);
        emit AavePoolConfigured(newProvider, poolAddress);
    }

    /**
     * @notice Get pending Aave Pool Provider change (if any)
     * @return value Pending provider address
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingAavePoolProvider()
        public
        view
        returns (address value, uint64 eta, bool exists)
    {
        return (getPendingAddress(_pendingPoolProvider));
    }

    /**
     * @notice Enable or disable Aave integration
     * @param enabled True to enable, false to disable
     * @dev Timelock can enable or disable Aave. Guardian can only disable via guardianDisableAave() (down-only).
     *      This allows Timelock to disable Aave if needed (e.g., for maintenance), while Guardian has emergency disable power.
     */
    function setAaveEnabled(bool enabled) public onlyRole(ROLE_TIMELOCK) {
        if (enabled && address(aavePool) == address(0)) {
            revert AavePoolNotConfigured();
        }
        aaveEnabled = enabled;
        emit AaveEnabledUpdated(enabled);
    }

    /**
     * @notice Guardian emergency function: Disable Aave integration
     * @dev Guardian can only disable (down-only). Cannot enable. Timelock must enable via setAaveEnabled(true).
     */
    function guardianDisableAave() public onlyRole(ROLE_GUARDIAN) {
        aaveEnabled = false;
        emit AaveDisabledByGuardian();
        emit AaveEnabledUpdated(false);
    }

    /**
     * @notice Register a token for Aave support
     * @param token ERC20 token address
     * @param aToken Corresponding aToken address
     */
    /**
     * @notice Sweep accumulated dust (timelock only)
     * @param token Token address
     * @param recipient Recipient of the dust
     */
    function sweepDust(address token, address recipient) external onlyRole(ROLE_TIMELOCK) {
        uint256 amount = protocolDust[token];
        if (amount == 0) return;
        
        protocolDust[token] = 0;
        IERC20(token).safeTransfer(recipient, amount);
        
        emit DustSwept(token, recipient, amount);
    }

    /**
     * @notice Register a token and its corresponding aToken for Aave yield generation
     * @param token Underlying token address
     * @param aToken Aave aToken address
     */
    function registerTokenForAave(address token, address aToken) public onlyRole(ROLE_TIMELOCK) {
        if (token == address(0)) {
            revert InvalidAddress(uint8(ADDR_TOKEN), token);
        }
        if (aToken == address(0)) {
            revert InvalidAddress(uint8(ADDR_ATOKEN), aToken);
        }

        // Verify aToken is valid by checking underlying asset
        // Try UNDERLYING_ASSET_ADDRESS() first (Aave V3 canonical method)
        address underlying;
        bool success;
        bytes memory returnData;

        // Try UNDERLYING_ASSET_ADDRESS() (Aave V3 standard)
        (success, returnData) = aToken.staticcall(
            abi.encodeWithSelector(bytes4(keccak256("UNDERLYING_ASSET_ADDRESS()")))
        );
        
        if (success && returnData.length == 32) {
            // Decode the address (skip the first 12 bytes, last 20 bytes are the address)
            underlying = abi.decode(returnData, (address));
        } else {
            // Fallback to underlyingAsset() (some wrappers/forks use this)
            (success, returnData) = aToken.staticcall(
                abi.encodeWithSelector(bytes4(keccak256("underlyingAsset()")))
            );
            
            if (success && returnData.length == 32) {
                underlying = abi.decode(returnData, (address));
            } else {
                // Neither method worked
                revert InvalidATokenAddress(token, aToken);
            }
        }

        // Validate underlying matches expected token
        if (underlying != token) {
            revert InvalidATokenAddress(token, aToken);
        }

        // State change after validation (checks-effects-interactions pattern)
        tokenToAToken[token] = aToken;
        emit TokenRegisteredForAave(token, aToken);
    }

    uint256 public constant MAX_BATCH_SIZE = 50;

    /**
     * @notice Batch register tokens for Aave support
     * @param tokens Array of ERC20 token addresses
     * @param aTokens Array of corresponding aToken addresses
     * @dev HIGH-3: Maximum batch size to prevent gas DoS
     */
    function batchRegisterTokensForAave(
        address[] memory tokens,
        address[] memory aTokens
    ) public onlyRole(ROLE_TIMELOCK) {
        // Prevent gas DoS with unbounded loops
        if (tokens.length > MAX_BATCH_SIZE) revert BatchSizeTooLarge(tokens.length, MAX_BATCH_SIZE);
        if (tokens.length != aTokens.length) {
            revert ArrayLengthMismatch(tokens.length, aTokens.length);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            registerTokenForAave(tokens[i], aTokens[i]);
        }
    }

    /**
     * @notice Check if a token is supported by Aave
     * @param token ERC20 token address
     * @return True if token is registered for Aave
     */
    function isTokenSupportedByAave(address token) public view returns (bool) {
        return tokenToAToken[token] != address(0);
    }

    // ============ Guardian Emergency Controls (Phase 4) ============

    /**
     * @notice Lower per-escrow cap in emergency (guardian only)
     * @param escrowContract Address of the vault
     * @param token Underlying token address
     * @param newCap New lower cap
     */
    function guardianLowerEscrowCap(address escrowContract, address token, uint256 newCap) external onlyRole(ROLE_GUARDIAN) {
        uint256 current = escrowCap[escrowContract][token];
        if (newCap > current) revert CapCannotBeRaised(newCap, current);
        
        escrowCap[escrowContract][token] = newCap;
        emit EscrowCapSet(escrowContract, token, current, newCap);
    }

    /**
     * @notice Lower global cap in emergency (guardian only)
     * @param token Underlying token address
     * @param newCap New lower cap
     */
    function guardianLowerGlobalCap(address token, uint256 newCap) public onlyRole(ROLE_GUARDIAN) {
        uint256 currentCap = globalCap[token];
        if (newCap > currentCap) revert CapCannotBeRaised(newCap, currentCap);
        globalCap[token] = newCap;
        emit GlobalCapSet(token, currentCap, newCap);
    }

    /**
     * @notice DEPRECATED - Use guardianLowerGlobalCap
     */
    function guardianLowerTokenCap(address token, uint256 newCap) external onlyRole(ROLE_GUARDIAN) {
        uint256 current = tokenCap[token];
        if (newCap > current) revert CapCannotBeRaised(newCap, current);
        tokenCap[token] = newCap;
        globalCap[token] = newCap; // Sync with globalCap
        emit TokenCapSet(token, current, newCap);
    }

    // ============ Timelock Cap Management (Phase 4) ============

    /**
     * @notice Set per-escrow fairness cap (timelock only)
     * @param escrowContract Address of the vault
     * @param token Underlying token address
     * @param newCap Maximum exposure allowed for this vault
     */
    function setEscrowCap(address escrowContract, address token, uint256 newCap) public onlyRole(ROLE_TIMELOCK) {
        if (newCap > CAP_MAX) revert CapExceeded(token, newCap, CAP_MAX);
        uint256 oldCap = escrowCap[escrowContract][token];
        escrowCap[escrowContract][token] = newCap;
        emit EscrowCapSet(escrowContract, token, oldCap, newCap);
    }

    /**
     * @notice DEPRECATED - Use setGlobalCap
     */
    function setTokenCap(address token, uint256 newCap) public onlyRole(ROLE_TIMELOCK) {
        if (newCap > CAP_MAX) revert CapExceeded(token, newCap, CAP_MAX);
        uint256 oldCap = tokenCap[token];
        tokenCap[token] = newCap;
        globalCap[token] = newCap; // Sync with globalCap
        emit TokenCapSet(token, oldCap, newCap);
    }

    /**
     * @notice Set global exposure cap for a token
     * @param token Token address
     * @param newCap New cap value (in raw token units, 0 = disabled)
     * @dev Timelock can set caps within bounds. Guardian can only lower via guardianLowerGlobalCap().
     *      Caps are enforced at deposit time. cap=0 disables deposits for that token.
     *      Maximum cap is type(uint128).max to prevent overflow.
     */
    function setGlobalCap(address token, uint256 newCap) public onlyRole(ROLE_TIMELOCK) {
        if (newCap > CAP_MAX) {
            revert CapExceeded(token, newCap, CAP_MAX);
        }
        uint256 oldCap = globalCap[token];
        globalCap[token] = newCap;
        emit GlobalCapSet(token, oldCap, newCap);
    }

    /**
     * @notice Internal function to check and update exposure
     * @param escrowContract Address of the calling vault
     * @param token Token address
     * @param amount Amount to add to exposure
     * @dev Reverts if caps would be exceeded
     */
    function _checkAndAccrueExposure(address escrowContract, address token, uint256 amount) internal {
        uint256 newExposure = currentExposure[token] + amount;

        // 1. System Safety: Global Cap
        uint256 globalCapValue = globalCap[token];
        if (globalCapValue > 0 && newExposure > globalCapValue) {
            revert CapExceeded(token, newExposure, globalCapValue);
        }

        // 2. Tenant Fairness: Per-Escrow Cap
        uint256 eCap = escrowCap[escrowContract][token];
        uint256 newEscrowTotal = currentEscrowExposure[escrowContract][token] + amount;
        if (eCap > 0 && newEscrowTotal > eCap) {
            revert EscrowCapExceeded(escrowContract, token, newEscrowTotal, eCap);
        }

        uint256 oldExposure = currentExposure[token];
        currentExposure[token] = newExposure;
        currentEscrowExposure[escrowContract][token] = newEscrowTotal;
        emit ExposureUpdated(token, oldExposure, newExposure);
    }

    /**
     * @notice Internal function to reduce exposure on withdrawal
     * @param escrowContract Address of the calling vault
     * @param token Token address
     * @param amount Amount to subtract from exposure
     */
    function _reduceExposure(address escrowContract, address token, uint256 amount) internal {
        uint256 oldExposure = currentExposure[token];
        if (amount > oldExposure) {
            currentExposure[token] = 0;
        } else {
            currentExposure[token] = oldExposure - amount;
        }

        if (amount > currentEscrowExposure[escrowContract][token]) {
            currentEscrowExposure[escrowContract][token] = 0;
        } else {
            currentEscrowExposure[escrowContract][token] -= amount;
        }

        emit ExposureUpdated(token, oldExposure, currentExposure[token]);
    }

    /**
     * @notice Get total amount deposited to Aave for a token
     * @param token ERC20 token address
     * @return Total amount deposited
     */
    function getTotalDepositedToAave(address token) public view returns (uint256) {
        return totalDepositedToAave[token];
    }

    /**
     * @notice Get escrow's Aave tracking data
     * @param escrowContract Address of the escrow contract
     * @param workflowId The escrow transfer ID
     * @return inAave True if escrow is in Aave
     * @return aTokenBalance aToken balance at deposit
     * @return originalDeposit Original deposit amount
     */
    function getEscrowAaveData(
        address escrowContract,
        uint256 workflowId
    ) public view returns (bool inAave, uint256 aTokenBalance, uint256 originalDeposit) {
        return (
            escrowInAave[escrowContract][workflowId],
            escrowScaledBalance[escrowContract][workflowId],
            escrowOriginalDeposit[escrowContract][workflowId]
        );
    }

    /**
     * @notice Get Aave pool address (for library pattern)
     * @return poolAddress Aave V3 Pool address (address(0) if not configured)
     */
    function getAavePoolAddress() external view returns (address poolAddress) {
        return address(aavePool);
    }

    /**
     * @notice Get aToken address for a token (for library pattern)
     * @param token Underlying token address
     * @return aTokenAddress aToken address (address(0) if token not supported)
     */
    function getATokenAddress(address token) external view returns (address aTokenAddress) {
        return tokenToAToken[token];
    }

    // ==================== ERC-4626 Escrow-Specific Methods ====================
    // These methods track shares per-escrow (workflowId) for yield calculation

    /**
     * @notice Deposit assets for an escrow, minting shares
     * @dev ERC-4626 compatible: takes assets, returns shares
     * @param workflowId The escrow workflow ID (from BaseEscrow)
     * @param asset The underlying token to deposit
     * @param assets Amount of assets to deposit
     * @return shares Amount of shares minted
     */
    function depositForEscrow(
        uint256 workflowId,
        address asset,
        uint256 assets
    ) external returns (uint256 shares) {
        address escrowContract = _msgSender();
        // Ensure Aave is enabled
        if (!aaveEnabled) {
            revert("Aave not enabled");
        }

        // Check that token is registered
        address aToken = tokenToAToken[asset];
        if (aToken == address(0)) {
            revert("Token not supported by Aave");
        }

        // Transfer assets from caller to this module
        IERC20(asset).safeTransferFrom(escrowContract, address(this), assets);

        // Calculate shares to mint (1:1 for first deposit, then use conversion)
        if (totalSupply() == 0) {
            shares = assets; // First deposit, 1:1 ratio
        } else {
            shares = _convertToShares(assets);
        }

        // Mint shares to this contract (held in escrowShares)
        _mint(address(this), shares);

        // Track escrow-specific data
        escrowShares[escrowContract][workflowId] += shares;
        escrowPrincipal[escrowContract][workflowId] += assets;

        // Approve pool and deposit to Aave
        uint256 currentAllowance = IERC20(asset).allowance(address(this), address(aavePool));
        if (currentAllowance < assets) {
            if (currentAllowance > 0) {
                IERC20(asset).safeDecreaseAllowance(address(aavePool), currentAllowance);
            }
            IERC20(asset).safeIncreaseAllowance(address(aavePool), assets);
        }
        
        aavePool.supply(asset, assets, address(this), 0);

        return shares;
    }

    /**
     * @notice Redeem shares for an escrow, returning assets
     * @dev ERC-4626 compatible: takes shares, returns assets
     * @param workflowId The escrow workflow ID (from BaseEscrow)
     * @param asset The underlying token to redeem
     * @param shares Amount of shares to redeem
     * @return assets Amount of assets returned
     */
    function redeemForEscrow(
        uint256 workflowId,
        address asset,
        uint256 shares
    ) external returns (uint256 assets) {
        address escrowContract = _msgSender();
        // Ensure workflow has shares to redeem
        if (escrowShares[escrowContract][workflowId] < shares) {
            revert("Insufficient shares for escrow");
        }

        // Calculate assets to return
        assets = _convertToAssets(shares);

        // Burn the shares
        _burn(address(this), shares);

        // Update escrow tracking
        escrowShares[escrowContract][workflowId] -= shares;
        uint256 principal = escrowPrincipal[escrowContract][workflowId];
        if (principal >= assets) {
            escrowPrincipal[escrowContract][workflowId] -= assets;
        } else {
            escrowPrincipal[escrowContract][workflowId] = 0;
        }

        // Withdraw from Aave
        uint256 withdrawn = aavePool.withdraw(asset, assets, address(this));

        // Transfer assets to caller
        IERC20(asset).safeTransfer(escrowContract, withdrawn);

        return withdrawn;
    }

    /**
     * @notice Get shares allocated to an escrow
     * @param escrowContract Address of the escrow contract
     * @param workflowId The escrow workflow ID
     * @return shares Amount of shares for this escrow
     */
    function sharesOfEscrow(address escrowContract, uint256 workflowId) external view returns (uint256) {
        return escrowShares[escrowContract][workflowId];
    }

    /**
     * @notice Get principal deposited for an escrow
     * @param escrowContract Address of the escrow contract
     * @param workflowId The escrow workflow ID
     * @return principal Amount of principal for this escrow
     */
    function principalOfEscrow(address escrowContract, uint256 workflowId) external view returns (uint256) {
        return escrowPrincipal[escrowContract][workflowId];
    }

    /**
     * @notice Calculate yield earned for an escrow
     * @dev yield = currentValue - principal
     * @param escrowContract Address of the escrow contract
     * @param workflowId The escrow workflow ID
     * @return yield Amount of yield earned
     */
    function yieldOfEscrow(address escrowContract, uint256 workflowId) external view returns (uint256) {
        uint256 shares = escrowShares[escrowContract][workflowId];
        uint256 principal = escrowPrincipal[escrowContract][workflowId];

        if (shares == 0 || totalSupply() == 0) {
            return 0;
        }

        // Convert shares back to assets to get current value
        uint256 currentValue = _convertToAssets(shares);
        
        if (currentValue > principal) {
            return currentValue - principal;
        }
        return 0;
    }

    /**
     * @notice Internal helper to convert assets to shares
     * @param assets Amount of assets
     * @return shares Equivalent shares
     */
    function _convertToShares(uint256 assets) internal view returns (uint256 shares) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets;
        }
        // shares = assets * totalSupply / totalAssets
        return (assets * supply) / totalAssets();
    }

    /**
     * @notice Internal helper to convert shares to assets
     * @param shares Amount of shares
     * @return assets Equivalent assets
     */
    function _convertToAssets(uint256 shares) internal view returns (uint256 assets) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return shares;
        }
        // assets = shares * totalAssets / totalSupply
        return (shares * totalAssets()) / supply;
    }

    /**
     * @notice Emergency unwind funds from Aave (guardian only)
     * @param token Underlying token address
     * @param workflowId The escrow transfer ID to unwind
     * @param escrowContract Address of the escrow contract (funds will be sent here)
     * @return unwoundAmount Actual underlying amount unwound
     * @dev Guardian can only trigger withdrawal back to the legitimate vault owner.
     *      Must not be able to transfer money to arbitrary addresses.
     */
    function emergencyUnwind(
        address token,
        uint256 workflowId,
        address escrowContract
    ) external onlyRole(ROLE_GUARDIAN) returns (uint256 unwoundAmount) {
        if (escrowContract == address(0)) revert InvalidAddress(uint8(ADDR_RECIPIENT), escrowContract);
        if (!escrowInAave[escrowContract][workflowId]) return 0;

        uint256 trackedScaledBalance = escrowScaledBalance[escrowContract][workflowId];
        uint256 originalDeposit = escrowOriginalDeposit[escrowContract][workflowId];
        address aToken = tokenToAToken[token];

        // Calculate underlying to withdraw based on shares
        uint256 currentATokenBalance = IAaveAToken(aToken).balanceOf(address(this));
        uint256 withdrawalAmount = (currentATokenBalance * trackedScaledBalance) / totalScaledBalance[token];

        // Ensure we withdraw at least 1 unit if shares exist (prevent rounding to 0)
        if (withdrawalAmount == 0 && trackedScaledBalance > 0) {
            withdrawalAmount = 1;
        }

        // Track scaled balance before and after to accurately update totalScaledBalance
        uint256 scaledBalanceBefore = IAaveAToken(aToken).scaledBalanceOf(address(this));

        // Withdraw from Aave - funds go STRICTLY back to the escrow vault
        unwoundAmount = aavePool.withdraw(token, withdrawalAmount, escrowContract);
        
        uint256 scaledBalanceAfter = IAaveAToken(aToken).scaledBalanceOf(address(this));
        uint256 burnedShares = scaledBalanceBefore > scaledBalanceAfter ? scaledBalanceBefore - scaledBalanceAfter : trackedScaledBalance;

        // Clear escrow state
        escrowInAave[escrowContract][workflowId] = false;
        escrowScaledBalance[escrowContract][workflowId] = 0;
        escrowOriginalDeposit[escrowContract][workflowId] = 0;

        // Update global tracking
        if (totalDepositedToAave[token] >= originalDeposit) {
            totalDepositedToAave[token] -= originalDeposit;
        }
        if (totalScaledBalance[token] >= burnedShares) {
            totalScaledBalance[token] -= burnedShares;
        }
        
        // Reduce exposure tracking
        _reduceExposure(escrowContract, token, unwoundAmount);

        // Dust handling (5 wei threshold)
        uint256 finalUnwound = unwoundAmount;
        uint256 dustThreshold = 5;

        if (unwoundAmount >= originalDeposit) {
            uint256 excess = unwoundAmount - originalDeposit;
            if (excess > 0 && excess <= dustThreshold) {
                protocolDust[token] += excess;
                emit DustAccumulated(token, excess);
                finalUnwound = originalDeposit;
            }
        } else {
            uint256 shortfall = originalDeposit - unwoundAmount;
            if (shortfall <= dustThreshold) {
                if (protocolDust[token] >= shortfall) {
                    protocolDust[token] -= shortfall;
                } else {
                    uint256 remainingShortfall = shortfall - protocolDust[token];
                    protocolDust[token] = 0;
                    protocolDeficit[token] += remainingShortfall;
                    emit DeficitAccumulated(token, remainingShortfall);
                }
                finalUnwound = originalDeposit;
            }
        }

        emit EscrowWithdrawnFromAave(workflowId, token, originalDeposit, finalUnwound, 0);

        return finalUnwound;
    }
}
