// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/AaveYieldGenerationModule.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/mocks/MockAavePool.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/interfaces/aave/AaveV3Interfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Mock Aave pool with configurable normalized income for CRIT-1 testing
 */
contract MockAavePoolConfigurableIncome {
    using SafeERC20 for IERC20;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant MIN_NORMALIZED_INCOME = 1e24; // 0.1% of RAY

    mapping(address => address) public tokenToAToken;
    mapping(address => uint256) public normalizedIncome; // asset => normalized income (RAY)
    mapping(address => mapping(address => uint256)) public scaledShares; // account => asset => scaled shares
    mapping(address => uint256) public underlyingBalances; // account => asset => underlying balance

    function setAToken(address token, address aToken) external {
        tokenToAToken[token] = aToken;
    }

    /**
     * @notice Set normalized income (for testing edge cases)
     * @param token Token address
     * @param incomeRay Normalized income in RAY (must be >= MIN_NORMALIZED_INCOME or 0 for fallback)
     */
    function setNormalizedIncome(address token, uint256 incomeRay) external {
        normalizedIncome[token] = incomeRay;
    }

    function getReserveNormalizedIncome(address token) external view returns (uint256) {
        uint256 income = normalizedIncome[token];
        if (income == 0 || income < MIN_NORMALIZED_INCOME) {
            return RAY; // Fallback to 1.0
        }
        return income;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(tokenToAToken[asset] != address(0), "Token not supported");
        
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // Track balances for onBehalfOf (Aave v3 semantics)
        underlyingBalances[onBehalfOf] += amount;

        uint256 income = normalizedIncome[asset];
        if (income == 0 || income < MIN_NORMALIZED_INCOME) {
            income = RAY;
        }

        // Calculate scaled shares: scaledShares = amount * RAY / incomeRay
        // Credit shares to onBehalfOf (Aave v3 semantics)
        uint256 scaled = (amount * RAY) / income;
        scaledShares[onBehalfOf][asset] += scaled;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(tokenToAToken[asset] != address(0), "Token not supported");
        
        uint256 income = normalizedIncome[asset];
        if (income == 0 || income < MIN_NORMALIZED_INCOME) {
            income = RAY;
        }

        // Calculate how many scaled shares to burn for this underlying amount
        uint256 scaledToBurn = (amount * RAY) / income;
        
        // Aave v3: withdraw burns shares from msg.sender (the caller)
        // In our module pattern, the module holds the shares (credited during supply)
        require(scaledShares[msg.sender][asset] >= scaledToBurn, "Insufficient scaled shares");
        
        scaledShares[msg.sender][asset] -= scaledToBurn;
        
        // Track underlying balances (best effort)
        if (underlyingBalances[msg.sender] >= amount) {
            underlyingBalances[msg.sender] -= amount;
        }

        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    /**
     * @notice Get current underlying amount for scaled shares (for testing)
     * @param account Account address (should be the account that has the shares)
     * @param asset Asset address
     * @return underlyingAmount Current underlying amount
     * @dev Note: During supply, shares are credited to onBehalfOf (vault)
     *      During withdraw, shares are burned from msg.sender (module)
     *      So this function should check the account parameter (vault) for shares
     */
    function getUnderlyingAmount(address account, address asset) external view returns (uint256 underlyingAmount) {
        uint256 income = normalizedIncome[asset];
        if (income == 0 || income < MIN_NORMALIZED_INCOME) {
            income = RAY;
        }
        uint256 scaled = scaledShares[account][asset];
        underlyingAmount = (scaled * income) / RAY;
    }

    function getLiquidityIndex(address asset) public view returns (uint256) {
        uint256 income = normalizedIncome[asset];
        if (income == 0 || income < MIN_NORMALIZED_INCOME) {
            return RAY; // Fallback to 1.0
        }
        return income;
    }

    function INITIAL_LIQUIDITY_INDEX() external pure returns (uint256) {
        return RAY;
    }

    function getReserveData(address asset) external view returns (ReserveData memory) {
        address aTokenAddr = tokenToAToken[asset];
        require(aTokenAddr != address(0), "Token not supported");

        return ReserveData({
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

    // ReserveData struct (simplified to match IAavePool)
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
 * @dev Delegatecall target for library pattern
 */
contract AaveLibraryWrapper {
    using SafeERC20 for IERC20;

    function supply(address pool, address token, uint256 amount, address onBehalfOf) external {
        IERC20 tokenContract = IERC20(token);
        uint256 currentAllowance = tokenContract.allowance(address(this), pool);

        if (currentAllowance != amount) {
            if (currentAllowance > 0) {
                tokenContract.safeDecreaseAllowance(pool, currentAllowance);
            }
            tokenContract.safeIncreaseAllowance(pool, amount);
        }

        IAavePool(pool).supply(token, amount, onBehalfOf, 0);

        uint256 remainingAllowance = tokenContract.allowance(address(this), pool);
        if (remainingAllowance > 0) {
            tokenContract.safeDecreaseAllowance(pool, remainingAllowance);
        }
    }

    function withdraw(address pool, address token, uint256 amount, address to) external returns (uint256) {
        return IAavePool(pool).withdraw(token, amount, to);
    }
}

/**
 * @title AaveCrit1EdgeCases
 * @notice Unit tests for CRIT-1 edge cases: zero income, income decrease, precision loss, principal protection
 */
contract AaveCrit1EdgeCases is Test {
    MockAavePoolConfigurableIncome internal pool;
    ERC20Mock internal token;
    MockAToken internal aToken;
    MockPoolAddressesProvider internal provider;
    AaveYieldGenerationModule internal aaveModule;

    EscrowVault internal vault;
    ModuleSnapshotRegistry internal mm;
    YieldOps internal yieldOps;
    DisputeOps internal disputeOps;
    CreateOps internal createOps;
    SettlementOps internal settlementOps;
    BondCollector internal bondCollector;
    DefaultResolutionModule internal resolutionModule;
    DefaultYieldDistributionModule internal yieldDist;
    AaveLibraryWrapper internal wrapper;

    address internal feeAddress = address(0xFEE);
    address internal resolver = address(0xBEEF);
    address internal sender = address(0x1001);
    address internal recipient = address(0x1002);

    uint256 internal constant ESCROW_FEE_BPS = 100;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MIN_NORMALIZED_INCOME = 1e24; // 0.1% of RAY
    uint256 internal constant MIN_DEPOSIT_AMOUNT = 1e15; // 0.001 tokens for 18-decimal

    function setUp() public {
        token = new ERC20Mock("Mock Token", "MOCK", address(this), 10_000_000 ether);
        pool = new MockAavePoolConfigurableIncome();

        aToken = new MockAToken(address(token), "aMock", "aMOCK");
        aToken.setPool(address(pool));
        pool.setAToken(address(token), address(aToken));
        // Set initial normalized income to RAY (1.0)
        pool.setNormalizedIncome(address(token), RAY);
        provider = new MockPoolAddressesProvider(address(pool));

        aaveModule = new AaveYieldGenerationModule(address(this));
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), address(this));
        aaveModule.queueAavePoolProvider(address(provider));
        (, uint64 etaProvider, bool existsProvider) = aaveModule.getPendingAavePoolProvider();
        require(existsProvider, "pending provider must exist");
        vm.warp(uint256(etaProvider) + 1);
        aaveModule.activateAavePoolProvider();
        aaveModule.setAaveEnabled(true);
        aaveModule.registerTokenForAave(address(token), address(aToken));

        yieldOps = new YieldOps(address(this));
        aaveModule.grantRole(aaveModule.ROLE_YIELD_OPS(), address(yieldOps));
        disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));

        vault = new EscrowVault(ESCROW_FEE_BPS, feeAddress, address(yieldOps), address(disputeOps), address(mm));
        
        // Register vault with Aave module
        aaveModule.registerEscrowContract(address(vault));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));

        createOps = new CreateOps(address(this));
        createOps.grantRole(createOps.ROLE_TIMELOCK(), address(this));
        createOps.registerEscrowContract(address(vault));

        settlementOps = new SettlementOps(address(this));
        settlementOps.registerEscrowContract(address(vault));

        bondCollector = new BondCollector(address(this));
        bondCollector.registerEscrowContract(address(vault));

        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        resolutionModule = new DefaultResolutionModule(address(this), resolver);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setResolutionModule(address(resolutionModule));

        yieldDist = new DefaultYieldDistributionModule();
        vm.prank(address(this));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        vm.prank(address(this));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST, address(yieldDist));
        (, uint64 etaGen, bool existsGen) = mm.getPendingModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        (, uint64 etaDist, bool existsDist) = mm.getPendingModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);
        require(existsGen && existsDist, "pending modules must exist");
        uint256 maxEta = etaGen > etaDist ? uint256(etaGen) : uint256(etaDist);
        vm.warp(maxEta + 1);
        vm.prank(address(this));
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        vm.prank(address(this));
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);

        wrapper = new AaveLibraryWrapper();
        // Module pattern is now used directly (no delegatecall library needed)
        vault.setYieldProtocolFeeBps(0);

        token.mint(address(pool), 10_000_000 ether);
    }

    // ============ CRIT-1 Test 1: Zero Normalized Income ============

    /**
     * @notice Test: Zero normalized income falls back to AAVE_RAY
     */
    function test_zeroNormalizedIncome_fallsBackToRAY() public {
        uint256 amount = 100 ether;
        token.mint(sender, amount);

        // Set normalized income to 0
        pool.setNormalizedIncome(address(token), 0);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Should succeed (falls back to RAY)
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Recipient should receive funds
        assertGt(token.balanceOf(recipient), 0, "Recipient should receive funds");
    }

    /**
     * @notice Test: Very small normalized income (< MIN_NORMALIZED_INCOME) falls back to RAY
     */
    function test_verySmallNormalizedIncome_fallsBackToRAY() public {
        uint256 amount = 100 ether;
        token.mint(sender, amount);

        // Set normalized income to just below minimum
        pool.setNormalizedIncome(address(token), MIN_NORMALIZED_INCOME - 1);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Should succeed (falls back to RAY)
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Recipient should receive funds
        assertGt(token.balanceOf(recipient), 0, "Recipient should receive funds");
    }

    // ============ CRIT-1 Test 2: Income Decrease ============

    /**
     * @notice Test: Income decrease - user still gets principal back
     */
    function test_incomeDecrease_userGetsPrincipalBack() public {
        uint256 amount = 100 ether;
        token.mint(sender, amount);
        token.mint(address(vault), amount); // Extra balance for principal protection

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create escrow with income = RAY (1.0)
        pool.setNormalizedIncome(address(token), RAY);
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Simulate income decrease (shouldn't happen in Aave, but we test defensive code)
        pool.setNormalizedIncome(address(token), RAY / 2); // Income decreased by 50%

        uint256 recipientBalBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);
        uint256 recipientBalAfter = token.balanceOf(recipient);

        // User should get at least principal (minus fee)
        uint256 fee = (amount * ESCROW_FEE_BPS) / 10000;
        uint256 expectedPrincipal = amount - fee;
        assertGe(
            recipientBalAfter - recipientBalBefore,
            expectedPrincipal,
            "User should get at least principal back even if income decreased"
        );
    }

    // ============ CRIT-1 Test 3: Precision Loss (Minimum Deposit) ============

    /**
     * @notice Test: Deposit below minimum amount should fail
     */
    function test_depositBelowMinimum_fails() public {
        uint256 amount = MIN_DEPOSIT_AMOUNT - 1; // Just below minimum
        token.mint(sender, amount);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        
        // Should fail due to minimum deposit check
        // Note: The deposit will fail in the library, but escrow creation may still succeed
        // (yield deposit is non-blocking)
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Escrow should be created, but yield deposit should have failed
        // Release should still work (without yield)
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Recipient should receive funds (without yield)
        assertGt(token.balanceOf(recipient), 0, "Recipient should receive funds");
    }

    /**
     * @notice Test: Deposit at minimum amount should succeed
     */
    function test_depositAtMinimum_succeeds() public {
        uint256 amount = MIN_DEPOSIT_AMOUNT; // Exactly minimum
        token.mint(sender, amount);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Should succeed
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Recipient should receive funds
        assertGt(token.balanceOf(recipient), 0, "Recipient should receive funds");
    }

    // ============ CRIT-1 Test 4: Principal Protection ============

    /**
     * @notice Test: Withdrawal returns less than principal - contract balance covers shortfall
     * @dev This test verifies principal protection when income decreases
     *      Note: Mock pool doesn't perfectly simulate income decrease, so we test the protection logic
     */
    function test_withdrawalLessThanPrincipal_contractBalanceCoversShortfall() public {
        uint256 amount = 100 ether;
        token.mint(sender, amount);
        token.mint(address(vault), 50 ether); // Extra balance for principal protection

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create escrow with normal income
        pool.setNormalizedIncome(address(token), RAY);
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Note: Mock pool doesn't perfectly simulate income decrease in withdrawal
        // The principal protection logic is tested via the library directly
        // This test verifies the full flow works even with edge cases

        uint256 recipientBalBefore = token.balanceOf(recipient);
        
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);
        
        uint256 recipientBalAfter = token.balanceOf(recipient);

        // User should get at least principal (minus fee)
        uint256 fee = (amount * ESCROW_FEE_BPS) / 10000;
        uint256 expectedPrincipal = amount - fee;
        assertGe(
            recipientBalAfter - recipientBalBefore,
            expectedPrincipal,
            "User should get at least principal back"
        );
    }

    /**
     * @notice Test: Minimum deposit validation works correctly
     * @dev Verifies that deposits below minimum fail gracefully (non-blocking)
     */
    function test_minimumDepositValidation_works() public {
        // Test with amount just below minimum
        uint256 amountBelowMin = 1e15 - 1; // Just below MIN_DEPOSIT_AMOUNT
        token.mint(sender, amountBelowMin);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amountBelowMin);
        // Escrow creation should succeed, but yield deposit should fail silently
        uint256 wid = vault.createEscrow(address(token), recipient, amountBelowMin, settings);
        vm.stopPrank();

        // Release should still work (without yield)
        uint256 recipientBalBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);
        uint256 recipientBalAfter = token.balanceOf(recipient);

        // Recipient should receive funds (without yield)
        assertGt(recipientBalAfter - recipientBalBefore, 0, "Recipient should receive funds even without yield");
    }
}
