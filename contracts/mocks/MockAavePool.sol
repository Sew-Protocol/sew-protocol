// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/**
 * @title MockAavePool
 * @notice Mock implementation of Aave Pool for testing
 */
contract MockAavePool {
    using SafeERC20 for IERC20;

    mapping(address => address) public tokenToAToken; // token => aToken
    mapping(address => mapping(address => uint256)) public deposits; // user => token => amount
    mapping(address => uint256) public liquidityIndex; // token => liquidity index (for yield simulation)

    uint256 public constant INITIAL_LIQUIDITY_INDEX = 1e27; // 1.0 with 27 decimals
    uint256 public constant YIELD_RATE = 1e25; // 1% per block (for testing)

    event Supply(
        address indexed asset,
        address indexed onBehalfOf,
        uint256 amount,
        uint16 referralCode
    );
    event Withdraw(address indexed asset, address indexed to, uint256 amount);

    constructor() {
        // Initialize liquidity index
    }

    function setAToken(address token, address aToken) external {
        tokenToAToken[token] = aToken;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(tokenToAToken[asset] != address(0), 'Token not supported');

        // Use SafeERC20 to handle tokens that don't return bool
        // Transfer from onBehalfOf (the escrow contract), not msg.sender (the module)
        IERC20(asset).safeTransferFrom(onBehalfOf, address(this), amount);
        deposits[onBehalfOf][asset] += amount;

        // Mint aTokens to onBehalfOf (mint the same amount as deposited)
        MockAToken aTokenContract = MockAToken(tokenToAToken[asset]);
        // Get current balance to calculate new balance
        uint256 currentBalance = aTokenContract.balanceOf(onBehalfOf);
        aTokenContract.mint(onBehalfOf, amount);
        // Verify the balance increased correctly
        require(
            aTokenContract.balanceOf(onBehalfOf) == currentBalance + amount,
            'aToken mint failed'
        );

        emit Supply(asset, onBehalfOf, amount, 0);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(tokenToAToken[asset] != address(0), 'Token not supported');

        MockAToken aTokenContract = MockAToken(tokenToAToken[asset]);

        // View calls first (checks)
        // aTokens are held by 'to' (the escrow contract), not msg.sender (the module)
        uint256 aTokenBalance = aTokenContract.balanceOf(to);
        require(amount <= aTokenBalance, 'Insufficient aToken balance');

        // Calculate actual underlying amount with yield
        uint256 actualAmount = _calculateWithYield(asset, amount);

        // Ensure we have enough tokens to transfer
        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        require(poolBalance >= actualAmount, 'Insufficient pool balance');

        // State changes before external calls (effects)
        deposits[to][asset] -= amount;

        // External calls after state changes (interactions)
        aTokenContract.burn(to, amount);
        IERC20(asset).safeTransfer(to, actualAmount);

        emit Withdraw(asset, to, actualAmount);
        return actualAmount;
    }

    function getReserveData(address asset) external view returns (ReserveData memory) {
        address aTokenAddr = tokenToAToken[asset];
        require(aTokenAddr != address(0), 'Token not supported');

        return
            ReserveData({
                configuration: ReserveConfigurationMap(0),
                liquidityIndex: uint128(
                    liquidityIndex[asset] > 0 ? liquidityIndex[asset] : INITIAL_LIQUIDITY_INDEX
                ),
                currentLiquidityRate: 0,
                variableBorrowIndex: 0,
                currentVariableBorrowRate: 0,
                currentStableBorrowRate: 0,
                lastUpdateTimestamp: 0,
                id: 0,
                aTokenAddress: aTokenAddr,
                stableDebtTokenAddress: address(0),
                variableDebtTokenAddress: address(0),
                interestRateStrategyAddress: address(0),
                accruedToTreasury: 0,
                unbacked: 0,
                isolationModeTotalDebt: 0
            });
    }

    // Simulate yield by increasing liquidity index
    function simulateYield(address token, uint256 blocks) external {
        if (liquidityIndex[token] == 0) {
            liquidityIndex[token] = INITIAL_LIQUIDITY_INDEX;
        }
        // Increase index by yield rate per block
        liquidityIndex[token] =
            liquidityIndex[token] +
            (liquidityIndex[token] * YIELD_RATE * blocks) /
            INITIAL_LIQUIDITY_INDEX;
    }

    function _calculateWithYield(address token, uint256 amount) internal view returns (uint256) {
        uint256 index = liquidityIndex[token] > 0 ? liquidityIndex[token] : INITIAL_LIQUIDITY_INDEX;
        return (amount * index) / INITIAL_LIQUIDITY_INDEX;
    }

    // ReserveData struct (simplified)
    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    struct ReserveConfigurationMap {
        uint256 data;
    }
}

/**
 * @title MockAToken
 * @notice Mock aToken implementation
 */
contract MockAToken is ERC20 {
    address public immutable underlyingAsset;
    MockAavePool public pool;

    constructor(
        address _underlyingAsset,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        underlyingAsset = _underlyingAsset;
    }

    function setPool(address _pool) external {
        pool = MockAavePool(_pool);
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == address(pool), 'Only pool can mint');
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == address(pool), 'Only pool can burn');
        _burn(from, amount);
    }
}

/**
 * @title MockPoolAddressesProvider
 * @notice Mock Pool Addresses Provider
 */
contract MockPoolAddressesProvider {
    address public pool;

    constructor(address _pool) {
        pool = _pool;
    }

    function getPool() external view returns (address) {
        return pool;
    }
}
