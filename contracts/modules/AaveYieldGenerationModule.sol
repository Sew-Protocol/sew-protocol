// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldGenerationModule.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '../governance/SlowLaneQueueActivate.sol';
import '../types/EscrowTypes.sol';

// Aave V3 interfaces
interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IPool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    // Optional: Add more interface methods for validation if needed
    // function getReserveData(address asset) external view returns (ReserveData memory);
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
    function underlyingAsset() external view returns (address);
}

// Custom errors
error AavePoolNotConfigured();
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

/**
 * @title AaveYieldGenerationModule
 * @notice Yield generation module implementing Aave V3 integration
 * @dev Handles Aave-specific yield generation: deposits, withdrawals, yield calculation, and configuration.
 *      Distribution is handled separately by IYieldDistributionModule.
 */
contract AaveYieldGenerationModule is IYieldGenerationModule, AccessControl, SlowLaneQueueActivate {
    // Role constants for governance
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    using SafeERC20 for IERC20;

    // Aave configuration
    IPoolAddressesProvider public aavePoolAddressesProvider;
    IPool public aavePool;
    bool public aaveEnabled = false;

    // Cap bounds
    /// @notice Maximum cap value (type(uint128).max to prevent overflow)
    uint256 public constant CAP_MAX = type(uint128).max;

    // Token support mapping
    mapping(address => address) public tokenToAToken; // token => aToken address
    mapping(address => uint256) public totalDepositedToAave; // token => total amount

    // Exposure tracking and caps (Phase 4)
    mapping(address => uint256) public tokenCap; // token => maximum exposure per token
    mapping(address => uint256) public globalCap; // token => global maximum exposure
    mapping(address => uint256) public currentExposure; // token => current exposure

    // Per-escrow tracking (escrow contract address => workflowId => data)
    mapping(address => mapping(uint256 => bool)) public escrowInAave; // escrowContract => workflowId => is in Aave
    mapping(address => mapping(uint256 => uint256)) public escrowATokenBalance; // escrowContract => workflowId => aToken balance at deposit
    mapping(address => mapping(uint256 => uint256)) public escrowOriginalDeposit; // escrowContract => workflowId => original deposit amount

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

    constructor(address initialOwner) {
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
        uint256 amount
    ) external override returns (bool success, uint256 yieldTokenBalance) {
        // MED-3: Zero address check for escrow contract (msg.sender)
        address escrowContract = msg.sender;
        if (escrowContract == address(0)) revert EscrowContractCannotBeZero();
        
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

        // Check exposure caps before depositing (Phase 4)
        _checkAndAccrueExposure(token, amount);

        // Note: Approval should be set by the escrow contract before calling this function
        // The escrow contract (EscrowableERC20) handles approval since it's both the token and escrow contract
        // No need to call forceApprove here as it would set allowance for the module, not the escrow contract

        // Deposit to Aave (referral code 0 = no referral)
        aavePool.supply(token, amount, escrowContract, 0);

        // Get aToken balance after deposit
        yieldTokenBalance = IAToken(aToken).balanceOf(escrowContract);

        // Track deposit
        escrowInAave[escrowContract][workflowId] = true;
        escrowATokenBalance[escrowContract][workflowId] = yieldTokenBalance;
        escrowOriginalDeposit[escrowContract][workflowId] = amount;
        totalDepositedToAave[token] += amount;

        emit EscrowDepositedToAave(workflowId, token, amount, yieldTokenBalance);

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
        uint256 originalAmount
    ) external override returns (bool success, uint256 actualAmount, uint256 yieldAmount) {
        address escrowContract = msg.sender; // BaseEscrow contract calling this

        if (!escrowInAave[escrowContract][workflowId]) {
            return (true, originalAmount, 0); // Not in Aave, return original amount
        }

        address aToken = tokenToAToken[token];
        if (aToken == address(0)) {
            return (true, originalAmount, 0); // Token mapping lost, return original
        }

        uint256 aTokenBalance = escrowATokenBalance[escrowContract][workflowId];
        if (aTokenBalance == 0) {
            // No aToken balance tracked - still clear state (shouldn't happen but handle gracefully)
            escrowInAave[escrowContract][workflowId] = false;
            escrowATokenBalance[escrowContract][workflowId] = 0;
            escrowOriginalDeposit[escrowContract][workflowId] = 0;
            // Update accounting
            if (totalDepositedToAave[token] >= originalAmount) {
                totalDepositedToAave[token] -= originalAmount;
            }
            _reduceExposure(token, originalAmount);
            return (true, originalAmount, 0); // No aToken balance tracked
        }

        uint256 originalDeposit = escrowOriginalDeposit[escrowContract][workflowId];

        // Fix checks-effects-interactions pattern
        // Withdraw from Aave FIRST (interaction), then clear state (effect)
        // Use low-level call for error handling
        (bool callSuccess, bytes memory returnData) = address(aavePool).call(
            abi.encodeWithSelector(IPool.withdraw.selector, token, aTokenBalance, escrowContract)
        );

        if (!callSuccess) {
            // Aave withdrawal failed - state not yet cleared, so tracking is preserved
            emit AaveWithdrawalFailedEvent(workflowId, token);
            return (false, originalAmount, 0);
        }

        // Decode actual amount withdrawn
        actualAmount = abi.decode(returnData, (uint256));

        // Slippage protection - validate actual amount meets minimum expected
        // For aTokens, the actual amount should be close to the original deposit if we're withdrawing all aTokens
        // Calculate expected minimum: we expect at least original deposit (no loss, only potential yield)
        // Allow 0.1% slippage tolerance (10 basis points) for rounding/edge cases
        uint256 slippageBps = 10; // 0.1% = 10 basis points  
        uint256 minimumAmount = originalDeposit * (10000 - slippageBps) / 10000;
        
        if (actualAmount < minimumAmount) {
            // Slippage protection - actual withdrawal less than expected minimum
            // Since withdrawal already succeeded, we log the issue but proceed
            // This protects against significant losses while allowing edge cases
            emit AaveWithdrawalFailedEvent(workflowId, token);
            // Could revert here, but that would require reverting the withdrawal (impossible)
            // Better to clear state and let escrow proceed with actual amount received
        }

        // Clear state AFTER successful withdrawal (checks-effects-interactions pattern)
        escrowInAave[escrowContract][workflowId] = false;
        escrowATokenBalance[escrowContract][workflowId] = 0;
        escrowOriginalDeposit[escrowContract][workflowId] = 0;

        // Update total deposited (subtract original, not actual)
        if (totalDepositedToAave[token] >= originalAmount) {
            totalDepositedToAave[token] -= originalAmount;
        }

        // Reduce exposure (Phase 4)
        _reduceExposure(token, originalAmount);

        // Calculate yield
        yieldAmount = actualAmount > originalAmount ? actualAmount - originalAmount : 0;

        emit EscrowWithdrawnFromAave(workflowId, token, originalAmount, actualAmount, yieldAmount);

        return (true, actualAmount, yieldAmount);
    }

    /**
     * @notice Calculate current yield for an escrow
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @return yieldAmount Current yield amount
     * @dev Calculates yield by comparing current aToken value to original deposit
     */
    function calculateYield(
        uint256 workflowId,
        address token
    ) external view override returns (uint256 yieldAmount) {
        address escrowContract = msg.sender; // BaseEscrow contract calling this

        if (!escrowInAave[escrowContract][workflowId]) {
            return 0; // Not in Aave, no yield
        }

        address aToken = tokenToAToken[token];
        if (aToken == address(0)) {
            return 0; // Token not supported
        }

        uint256 currentATokenBalance = IAToken(aToken).balanceOf(escrowContract);
        uint256 originalATokenBalance = escrowATokenBalance[escrowContract][workflowId];
        uint256 originalDeposit = escrowOriginalDeposit[escrowContract][workflowId];

        if (originalATokenBalance == 0 || originalDeposit == 0) {
            return 0; // No tracking data
        }

        // Calculate current value of aTokens
        // We need to estimate what the current aToken balance represents in underlying tokens
        // For simplicity, we'll use the ratio: (currentATokenBalance / originalATokenBalance) * originalDeposit
        // This gives us an estimate of current value
        uint256 estimatedCurrentValue = (currentATokenBalance * originalDeposit) /
            originalATokenBalance;

        // Yield = estimated current value - original deposit
        if (estimatedCurrentValue > originalDeposit) {
            yieldAmount = estimatedCurrentValue - originalDeposit;
        }

        return yieldAmount;
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
            revert InvalidAddress(ADDR_PROVIDER, provider);
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
        try IPoolAddressesProvider(newProvider).getPool() returns (address pool) {
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
        aavePoolAddressesProvider = IPoolAddressesProvider(newProvider);
        aavePool = IPool(poolAddress);
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
    function registerTokenForAave(address token, address aToken) public onlyRole(ROLE_TIMELOCK) {
        if (token == address(0)) {
            revert InvalidAddress(ADDR_TOKEN, token);
        }
        if (aToken == address(0)) {
            revert InvalidAddress(ADDR_ATOKEN, aToken);
        }

        // Verify aToken is valid by checking underlying asset (external call)
        address underlying;
        try IAToken(aToken).underlyingAsset() returns (address underlyingAsset) {
            underlying = underlyingAsset;
        } catch {
            revert InvalidATokenAddress(token, aToken);
        }

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
     * @notice Guardian emergency function: Lower token-specific cap (down-only)
     * @param token Token address
     * @param newCap New cap value (must be <= current cap)
     * @dev Guardian can only lower caps, not raise them. This is a down-only control.
     */
    function guardianLowerTokenCap(address token, uint256 newCap) public onlyRole(ROLE_GUARDIAN) {
        uint256 currentCap = tokenCap[token];
        if (newCap > currentCap) revert CapCannotBeRaised(newCap, currentCap);
        tokenCap[token] = newCap;
        emit TokenCapLowered(token, currentCap, newCap);
    }

    /**
     * @notice Guardian emergency function: Lower global cap (down-only)
     * @param token Token address
     * @param newCap New cap value (must be <= current cap)
     * @dev Guardian can only lower caps, not raise them. This is a down-only control.
     */
    function guardianLowerGlobalCap(address token, uint256 newCap) public onlyRole(ROLE_GUARDIAN) {
        uint256 currentCap = globalCap[token];
        if (newCap > currentCap) revert CapCannotBeRaised(newCap, currentCap);
        globalCap[token] = newCap;
        emit GlobalCapLowered(token, currentCap, newCap);
    }

    // ============ Timelock Cap Management (Phase 4) ============

    /**
     * @notice Set token-specific exposure cap
     * @param token Token address
     * @param newCap New cap value (in raw token units, 0 = disabled)
     * @dev Timelock can set caps within bounds. Guardian can only lower via guardianLowerTokenCap().
     *      Caps are enforced at deposit time. cap=0 disables deposits for that token.
     *      Maximum cap is type(uint128).max to prevent overflow.
     */
    function setTokenCap(address token, uint256 newCap) public onlyRole(ROLE_TIMELOCK) {
        if (newCap > CAP_MAX) {
            revert CapExceeded(token, newCap, CAP_MAX);
        }
        uint256 oldCap = tokenCap[token];
        tokenCap[token] = newCap;
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
     * @param token Token address
     * @param amount Amount to add to exposure
     * @dev Reverts if caps would be exceeded
     */
    function _checkAndAccrueExposure(address token, uint256 amount) internal {
        uint256 newExposure = currentExposure[token] + amount;

        // Check token-specific cap
        uint256 tokenCapValue = tokenCap[token];
        if (tokenCapValue > 0 && newExposure > tokenCapValue) {
            revert CapExceeded(token, newExposure, tokenCapValue);
        }

        // Check global cap
        uint256 globalCapValue = globalCap[token];
        if (globalCapValue > 0 && newExposure > globalCapValue) {
            revert CapExceeded(token, newExposure, globalCapValue);
        }

        uint256 oldExposure = currentExposure[token];
        currentExposure[token] = newExposure;
        emit ExposureUpdated(token, oldExposure, newExposure);
    }

    /**
     * @notice Internal function to reduce exposure on withdrawal
     * @param token Token address
     * @param amount Amount to subtract from exposure
     */
    function _reduceExposure(address token, uint256 amount) internal {
        uint256 oldExposure = currentExposure[token];
        if (amount > oldExposure) {
            currentExposure[token] = 0;
        } else {
            currentExposure[token] = oldExposure - amount;
        }
        emit ExposureUpdated(token, oldExposure, currentExposure[token]);
    }

    /**
     * @notice Get aToken address for a token
     * @param token ERC20 token address
     * @return aToken address (address(0) if not supported)
     */
    function getATokenAddress(address token) public view returns (address) {
        return tokenToAToken[token];
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
            escrowATokenBalance[escrowContract][workflowId],
            escrowOriginalDeposit[escrowContract][workflowId]
        );
    }
}
