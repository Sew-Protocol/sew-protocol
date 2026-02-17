// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import 'contracts/mocks/ERC20Mock.sol';

/**
 * @title MockAavePool
 * @notice Mock implementation of Aave Pool for testing
 */
contract MockAavePool {
    using SafeERC20 for IERC20;

    mapping(address => address) public tokenToAToken; // token => aToken
    // Track deposits by the address that actually supplied (msg.sender), mirroring Aave semantics.
    mapping(address => mapping(address => uint256)) public deposits; // supplier => token => amount
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

    function getLiquidityIndex(address asset) public view returns (uint256) {
        return liquidityIndex[asset] > 0 ? liquidityIndex[asset] : INITIAL_LIQUIDITY_INDEX;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external virtual {
        require(tokenToAToken[asset] != address(0), 'Token not supported');

        uint256 currentIndex = getLiquidityIndex(asset);

        // Aave v3 semantics: Pool pulls underlying from msg.sender (the caller),
        // and mints aTokens to onBehalfOf.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        
        // Track supplied amount for withdraw
        deposits[onBehalfOf][asset] += amount;
        
        // Calculate scaled amount to mint
        uint256 scaledAmount = (amount * INITIAL_LIQUIDITY_INDEX) / currentIndex;
        
        MockAToken aTokenContract = MockAToken(tokenToAToken[asset]);
        aTokenContract.mint(onBehalfOf, scaledAmount);

        emit Supply(asset, onBehalfOf, amount, 0);
    }

    function withdraw(address asset, uint256 amount, address to) external virtual returns (uint256) {
        require(tokenToAToken[asset] != address(0), 'Token not supported');

        MockAToken aTokenContract = MockAToken(tokenToAToken[asset]);
        uint256 currentIndex = getLiquidityIndex(asset);

        // In Aave V3, 'amount' in withdraw is the amount of underlying requested.
        // We calculate how many scaled tokens to burn.
        uint256 scaledToBurn = (amount * INITIAL_LIQUIDITY_INDEX) / currentIndex;
        
        // Ensure msg.sender has enough scaled tokens
        require(aTokenContract.scaledBalanceOf(msg.sender) >= scaledToBurn, 'Insufficient scaled balance');

        // Burn scaled tokens
        aTokenContract.burn(msg.sender, scaledToBurn);

        // Use balance of pool (includes supplied + yield)
        uint256 poolBalance = IERC20(asset).balanceOf(address(this));
        require(poolBalance >= amount, 'Insufficient pool balance');

        IERC20(asset).safeTransfer(to, amount);

        emit Withdraw(asset, to, amount);
        return amount;
    }

    function getReserveData(address asset) external view returns (ReserveData memory) {
        address aTokenAddr = tokenToAToken[asset];
        require(aTokenAddr != address(0), 'Token not supported');

        return
            ReserveData({
                configuration: ReserveConfigurationMap(0),
                liquidityIndex: uint128(getLiquidityIndex(asset)),
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
        
        // Mint yield tokens to pool (simulating borrower interest payments to lenders)
        uint256 poolBalance = IERC20(token).balanceOf(address(this));
        uint256 yieldGenerated = (poolBalance * YIELD_RATE * blocks) / INITIAL_LIQUIDITY_INDEX;
        if (yieldGenerated > 0) {
            ERC20Mock(token).mint(address(this), yieldGenerated);
        }
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
 * @notice Mock aToken implementation that simulates rebasing balance
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

    /**
     * @dev Returns the rebased balance (scaled balance * liquidity index)
     */
    function balanceOf(address account) public view override returns (uint256) {
        uint256 scaledBalance = super.balanceOf(account);
        if (address(pool) == address(0)) return scaledBalance;
        
        uint256 currentIndex = pool.getLiquidityIndex(underlyingAsset);
        return (scaledBalance * currentIndex) / pool.INITIAL_LIQUIDITY_INDEX();
    }

    /**
     * @dev Returns the non-rebased (scaled) balance
     */
    function scaledBalanceOf(address account) public view returns (uint256) {
        return super.balanceOf(account);
    }

    function mint(address to, uint256 amount) external {
        require(_msgSender() == address(pool), 'Only pool can mint');
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(_msgSender() == address(pool), 'Only pool can burn');
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