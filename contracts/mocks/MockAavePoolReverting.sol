// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './MockAavePool.sol'; // Import MockAToken
/**
 * @title MockAavePoolReverting
 * @notice Mock Aave Pool that can be configured to revert withdrawals for testing
 * @dev Similar to MockAavePool but with ability to simulate failures and slippage
 */
contract MockAavePoolReverting {
    using SafeERC20 for IERC20;

    mapping(address => address) public tokenToAToken; // token => aToken
    // Track deposits by the address that actually supplied (msg.sender), mirroring Aave semantics.
    mapping(address => mapping(address => uint256)) public deposits; // supplier => token => amount
    mapping(address => uint256) public liquidityIndex; // token => liquidity index (for yield simulation)

    uint256 public constant INITIAL_LIQUIDITY_INDEX = 1e27; // 1.0 with 27 decimals
    uint256 public constant YIELD_RATE = 1e25; // 1% per block (for testing)

    bool public shouldRevertWithdraw = false;
    bool public shouldRevertSupply = false;
    uint256 public slippageBps = 0; // Slippage in basis points (0 = no slippage)

    event Supply(
        address indexed asset,
        address indexed onBehalfOf,
        uint256 amount,
        uint16 referralCode
    );
    event Withdraw(address indexed asset, address indexed to, uint256 amount);

    /**
     * @notice Set whether withdrawals should revert
     */
    function setShouldRevertWithdraw(bool _shouldRevert) external {
        shouldRevertWithdraw = _shouldRevert;
    }

    /**
     * @notice Set whether supply should revert
     */
    function setShouldRevertSupply(bool _shouldRevert) external {
        shouldRevertSupply = _shouldRevert;
    }

    /**
     * @notice Set slippage for withdrawals (in basis points)
     * @dev If slippage is set, actualAmount will be reduced by slippage percentage
     */
    function setSlippageBps(uint256 _slippageBps) external {
        slippageBps = _slippageBps;
    }

    function setAToken(address token, address aToken) external {
        tokenToAToken[token] = aToken;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        if (shouldRevertSupply) {
            revert('MockAavePool: Supply reverted for testing');
        }

        require(tokenToAToken[asset] != address(0), 'Token not supported');

        // Aave v3 semantics: Pool pulls underlying from msg.sender (the caller),
        // and mints aTokens to onBehalfOf.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender][asset] += amount;

        MockAToken aTokenContract = MockAToken(tokenToAToken[asset]);
        uint256 currentBalance = aTokenContract.balanceOf(onBehalfOf);
        aTokenContract.mint(onBehalfOf, amount);
        require(
            aTokenContract.balanceOf(onBehalfOf) == currentBalance + amount,
            'aToken mint failed'
        );

        emit Supply(asset, onBehalfOf, amount, 0);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        if (shouldRevertWithdraw) {
            revert('MockAavePool: Withdraw reverted for testing');
        }

        require(tokenToAToken[asset] != address(0), 'Token not supported');

        MockAToken aTokenContract = MockAToken(tokenToAToken[asset]);

        // Aave v3 semantics: Pool burns aTokens from msg.sender (the caller),
        // and sends underlying to `to`.
        uint256 aTokenBalance = aTokenContract.balanceOf(msg.sender);
        require(amount <= aTokenBalance, 'Insufficient aToken balance');

        // Calculate actual underlying amount with yield
        uint256 actualAmount = _calculateWithYield(asset, amount);

        // Apply slippage if configured
        if (slippageBps > 0) {
            actualAmount = actualAmount * (10000 - slippageBps) / 10000;
        }

        // Ensure we have enough tokens to transfer
        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        require(poolBalance >= actualAmount, 'Insufficient pool balance');

        // State changes before external calls (effects)
        deposits[msg.sender][asset] -= amount;

        // External calls after state changes (interactions)
        aTokenContract.burn(msg.sender, amount);
        IERC20(asset).safeTransfer(to, actualAmount);

        emit Withdraw(asset, to, actualAmount);
        return actualAmount;
    }

    function simulateYield(address token, uint256 blocks) external {
        if (liquidityIndex[token] == 0) {
            liquidityIndex[token] = INITIAL_LIQUIDITY_INDEX;
        }
        liquidityIndex[token] =
            liquidityIndex[token] +
            (liquidityIndex[token] * YIELD_RATE * blocks) /
            INITIAL_LIQUIDITY_INDEX;
    }

    function _calculateWithYield(address token, uint256 amount) internal view returns (uint256) {
        uint256 index = liquidityIndex[token] > 0 ? liquidityIndex[token] : INITIAL_LIQUIDITY_INDEX;
        return (amount * index) / INITIAL_LIQUIDITY_INDEX;
    }
}
