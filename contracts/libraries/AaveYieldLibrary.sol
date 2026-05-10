// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../interfaces/aave/AaveV3Interfaces.sol';

/**
 * @title AaveYieldLibrary
 * @notice Library for Aave V3 yield operations
 * @dev Uses delegatecall so msg.sender remains the caller (BaseEscrow)
 *      This ensures Aave semantics are correct (msg.sender owns tokens/aTokens)
 */
library AaveYieldLibrary {
    using SafeERC20 for IERC20;

    error InvalidAddress();
    error InvalidAmount();
    
    /**
     * @notice Supply tokens to Aave Pool
     * @param pool Aave V3 Pool address
     * @param token Underlying token address
     * @param amount Amount to supply
     * @param onBehalfOf Address to receive aTokens (typically BaseEscrow)
     * @dev msg.sender must own tokens and approve pool
     */
    function supply(
        address pool,
        address token,
        uint256 amount,
        address onBehalfOf
    ) external {
        if (pool == address(0) || token == address(0) || onBehalfOf == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        IERC20 tokenContract = IERC20(token);

        // Force exact allowance for the operation.
        SafeERC20.forceApprove(tokenContract, pool, amount);
        
        // Supply to Aave (msg.sender = BaseEscrow, pulls from BaseEscrow)
        IAavePool(pool).supply(token, amount, onBehalfOf, 0);
        
        // Reset approval to zero (safety)
        SafeERC20.forceApprove(tokenContract, pool, 0);
    }
    
    /**
     * @notice Withdraw tokens from Aave Pool
     * @param pool Aave V3 Pool address
     * @param token Underlying token address
     * @param amount aToken amount to withdraw
     * @param to Address to receive underlying tokens
     * @return actualAmount Actual underlying amount withdrawn
     * @dev msg.sender must own aTokens
     */
    function withdraw(
        address pool,
        address token,
        uint256 amount,
        address to
    ) external returns (uint256 actualAmount) {
        if (pool == address(0) || token == address(0) || to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        // Withdraw from Aave (msg.sender = BaseEscrow, burns BaseEscrow's aTokens)
        actualAmount = IAavePool(pool).withdraw(token, amount, to);
    }
}
