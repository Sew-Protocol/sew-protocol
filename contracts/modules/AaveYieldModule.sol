// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "../interfaces/IYieldModule.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

// Aave V3 interfaces
interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
    function underlyingAsset() external view returns (address);
}

// Custom errors
error AavePoolNotConfigured();
error TokenNotSupportedByAave(address token);
error InvalidATokenAddress(address token, address aToken);
error InvalidAddress(string reason, address addr);
error ArrayLengthMismatch(uint256 expectedLength, uint256 actualLength);
error AaveWithdrawalFailed(uint256 workflowId, address token);

/**
 * @title AaveYieldModule
 * @notice Yield module implementing Aave V3 integration for yield generation
 * @dev Handles all Aave-specific logic: deposits, withdrawals, yield calculation, and configuration
 */
contract AaveYieldModule is IYieldModule, Ownable, ERC165 {
    using SafeERC20 for IERC20;

    // Aave configuration
    IPoolAddressesProvider public aavePoolAddressesProvider;
    IPool public aavePool;
    bool public aaveEnabled = false;

    // Token support mapping
    mapping(address => address) public tokenToAToken; // token => aToken address
    mapping(address => uint256) public totalDepositedToAave; // token => total amount

    // Per-escrow tracking (escrow contract address => workflowId => data)
    mapping(address => mapping(uint256 => bool)) public escrowInAave; // escrowContract => workflowId => is in Aave
    mapping(address => mapping(uint256 => uint256)) public escrowATokenBalance; // escrowContract => workflowId => aToken balance at deposit
    mapping(address => mapping(uint256 => uint256)) public escrowOriginalDeposit; // escrowContract => workflowId => original deposit amount

    // Events
    event EscrowDepositedToAave(uint256 indexed escrowId, address indexed token, uint256 amount, uint256 aTokenBalance);
    event EscrowWithdrawnFromAave(uint256 indexed escrowId, address indexed token, uint256 originalAmount, uint256 actualAmount, uint256 yield);
    event AaveWithdrawalFailedEvent(uint256 indexed escrowId, address indexed token);
    event AavePoolConfigured(address indexed provider, address indexed pool);
    event AaveEnabledUpdated(bool enabled);
    event TokenRegisteredForAave(address indexed token, address indexed aToken);

    constructor(address initialOwner) Ownable(initialOwner) {}

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

        address escrowContract = msg.sender; // BaseEscrow contract calling this

        // Approve Aave Pool to spend tokens (from escrow contract)
        IERC20(token).forceApprove(address(aavePool), amount);

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
    ) external override returns (
        bool success,
        uint256 actualAmount,
        uint256 yieldAmount
    ) {
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
            return (true, originalAmount, 0); // No aToken balance tracked
        }

        // State changes BEFORE external call (checks-effects-interactions pattern)
        // Clear tracking state to prevent reentrancy
        escrowInAave[escrowContract][workflowId] = false;
        escrowATokenBalance[escrowContract][workflowId] = 0;
        escrowOriginalDeposit[escrowContract][workflowId] = 0;

        // Update total deposited (subtract original, not actual)
        if (totalDepositedToAave[token] >= originalAmount) {
            totalDepositedToAave[token] -= originalAmount;
        }

        // Withdraw from Aave (withdraws all aTokens for this escrow)
        // Use low-level call for error handling
        (bool callSuccess, bytes memory returnData) = address(aavePool).call(
            abi.encodeWithSelector(IPool.withdraw.selector, token, aTokenBalance, escrowContract)
        );

        if (callSuccess) {
            actualAmount = abi.decode(returnData, (uint256));
        } else {
            // Aave withdrawal failed, emit event and return original amount
            emit AaveWithdrawalFailedEvent(workflowId, token);
            return (false, originalAmount, 0);
        }

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
        uint256 estimatedCurrentValue = (currentATokenBalance * originalDeposit) / originalATokenBalance;

        // Yield = estimated current value - original deposit
        if (estimatedCurrentValue > originalDeposit) {
            yieldAmount = estimatedCurrentValue - originalDeposit;
        }

        return yieldAmount;
    }

    /**
     * @notice Distribute yield according to distribution data
     * @return success True if distribution was successful
     * @return distributedAmount Total amount distributed
     * @dev Delegates to DefaultYieldModule logic (distribution is not Aave-specific)
     *      This module focuses on yield generation, not distribution.
     *      Parameters are required by interface but unused in this implementation.
     */
    function distributeYield(
        uint256 /* workflowId */,
        address /* token */,
        uint256 /* yieldAmount */,
        bytes calldata /* distributionData */
    ) external pure override returns (bool success, uint256 distributedAmount) {
        // AaveYieldModule doesn't handle distribution - that's handled by BaseEscrow
        // or a separate distribution module. Return false to indicate this module
        // doesn't handle distribution (BaseEscrow will fallback to its own logic)
        return (false, 0);
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
    function getApprovalTarget(address token) external view override returns (address approvalTarget) {
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
        return "AaveYield";
    }

    // ============ Aave Configuration Functions ============

    /**
     * @notice Set Aave Pool Addresses Provider
     * @param provider Address of the Aave Pool Addresses Provider
     * @dev Sets the Aave Pool Addresses Provider and automatically retrieves the Pool address.
     *      Enables Aave integration if pool address is valid. Reverts if provider is zero address.
     */
    function setAavePoolAddressesProvider(address provider) public onlyOwner {
        if (provider == address(0)) {
            revert InvalidAddress("Provider address cannot be zero", provider);
        }
        aavePoolAddressesProvider = IPoolAddressesProvider(provider);
        // Get pool address first (external call)
        address poolAddress = aavePoolAddressesProvider.getPool();
        // Then update state (checks-effects-interactions pattern)
        aavePool = IPool(poolAddress);
        aaveEnabled = poolAddress != address(0);
        emit AavePoolConfigured(provider, poolAddress);
    }

    /**
     * @notice Enable or disable Aave integration
     * @param enabled True to enable, false to disable
     */
    function setAaveEnabled(bool enabled) public onlyOwner {
        if (enabled && address(aavePool) == address(0)) {
            revert AavePoolNotConfigured();
        }
        aaveEnabled = enabled;
        emit AaveEnabledUpdated(enabled);
    }

    /**
     * @notice Register a token for Aave support
     * @param token ERC20 token address
     * @param aToken Corresponding aToken address
     */
    function registerTokenForAave(address token, address aToken) public onlyOwner {
        if (token == address(0)) {
            revert InvalidAddress("Token address cannot be zero", token);
        }
        if (aToken == address(0)) {
            revert InvalidAddress("aToken address cannot be zero", aToken);
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

    /**
     * @notice Batch register tokens for Aave support
     * @param tokens Array of ERC20 token addresses
     * @param aTokens Array of corresponding aToken addresses
     */
    function batchRegisterTokensForAave(address[] memory tokens, address[] memory aTokens) public onlyOwner {
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
    function getEscrowAaveData(address escrowContract, uint256 workflowId) public view returns (
        bool inAave,
        uint256 aTokenBalance,
        uint256 originalDeposit
    ) {
        return (
            escrowInAave[escrowContract][workflowId],
            escrowATokenBalance[escrowContract][workflowId],
            escrowOriginalDeposit[escrowContract][workflowId]
        );
    }

    /**
     * @notice ERC165 interface support
     * @param interfaceId The interface identifier
     * @return True if the contract supports the interface
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return
            interfaceId == type(IYieldModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}


