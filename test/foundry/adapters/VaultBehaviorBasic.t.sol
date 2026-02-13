// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../adapters/IVaultLike.sol";
import "../adapters/AaveVaultAdapter.sol";
import "../../../contracts/modules/AaveYieldModule.sol";
import "../../../contracts/mocks/MockAavePool.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/interfaces/aave/AaveV3Interfaces.sol";

/**
 * @title VaultBehaviorBasicTest  
 * @notice Basic vault behavior tests using IVaultLike interface
 * @dev Tests AaveYieldModule through the adapter using standard vault semantics
 *      Uses forge-std assertions to validate ERC-4626-like behavior
 */
contract VaultBehaviorBasicTest is Test {
    IVaultLike public vault;
    AaveVaultAdapter public adapter;
    AaveYieldModule public aaveModule;
    MockAavePool public mockPool;
    ERC20Mock public underlying;
    MockAToken public aToken;
    
    address public userA = address(0xA11CE);
    address public userB = address(0xB0B);
    address public admin = address(this);
    
    // Tolerances for rounding
    uint256 constant ABS_TOLERANCE = 10; // 10 wei tolerance for rounding
    uint256 constant REL_TOLERANCE_BPS = 5; // 0.05% relative tolerance
    
    function setUp() public {
        // Deploy underlying token
        underlying = new ERC20Mock("Test Token", "TEST", admin, 1_000_000_000e18);
        
        // Deploy mock Aave pool
        mockPool = new MockAavePool();
        
        // Deploy aToken (mock)
        aToken = new MockAToken(address(underlying), "aTest Token", "aTEST");
        aToken.setPool(address(mockPool));
        
        // Configure mock pool
        mockPool.setAToken(address(underlying), address(aToken));
        
        // Deploy Aave module
        aaveModule = new AaveYieldModule(admin);
        
        // Configure Aave pool (using slow-lane queue mechanism)
        vm.startPrank(admin);
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), admin);
        
        // Deploy mock provider
        MockPoolAddressesProvider mockProvider = new MockPoolAddressesProvider(address(mockPool));
        
        // Queue and activate pool provider
        aaveModule.queueAavePoolProvider(address(mockProvider));
        (, uint64 eta, bool exists) = aaveModule.getPendingAavePoolProvider();
        require(exists, "pending provider must exist");
        vm.warp(uint256(eta) + 1); // Fast-forward past 7-day delay
        aaveModule.activateAavePoolProvider();
        
        // Enable Aave and register token
        aaveModule.setAaveEnabled(true);
        aaveModule.registerTokenForAave(address(underlying), address(aToken));
        vm.stopPrank();
        
        // Deploy adapter
        adapter = new AaveVaultAdapter(aaveModule, address(underlying));
        vault = IVaultLike(address(adapter));
        
        // Register adapter with Aave module
        vm.prank(admin);
        aaveModule.grantRole(aaveModule.ROLE_ESCROW_CONTRACT(), address(adapter));
        
        // Transfer tokens to users
        vm.prank(admin);
        underlying.transfer(userA, 1_000_000e18);
        vm.prank(admin);
        underlying.transfer(userB, 1_000_000e18);
        
        // Approve adapter
        vm.prank(userA);
        underlying.approve(address(adapter), type(uint256).max);
        vm.prank(userB);
        underlying.approve(address(adapter), type(uint256).max);
    }
    
    // ========== forge-std Assertion Tests ==========
    
    /**
     * @notice Test: asset() returns correct underlying
     */
    function test_asset_returnsUnderlying() public {
        assertEq(vault.asset(), address(underlying), "asset should return underlying token");
    }
    
    /**
     * @notice Test: deposit returns non-zero shares
     * @dev forge-std assertion: shares > 0 after deposit(assets)
     */
    function test_deposit_returnsNonZeroShares() public {
        uint256 assets = 100e18;
        
        vm.prank(userA);
        uint256 shares = vault.deposit(assets, userA);
        
        // ASSERT: shares > 0 after deposit
        assertGt(shares, 0, "deposit should return non-zero shares");
        
        // ASSERT: user's share balance updated
        assertEq(vault.balanceOf(userA), shares, "user balance should equal returned shares");
    }
    
    /**
     * @notice Test: deposit transfers assets and mints shares
     * @dev forge-std assertions: asset transfer and share minting
     */
    function test_deposit_transfersAssetsAndMintsShares() public {
        uint256 assets = 100e18;
        uint256 userBalanceBefore = underlying.balanceOf(userA);
        
        vm.prank(userA);
        uint256 shares = vault.deposit(assets, userA);
        
        // ASSERT: assets were transferred
        assertEq(
            underlying.balanceOf(userA),
            userBalanceBefore - assets,
            "user balance should decrease by assets"
        );
        
        // ASSERT: shares were minted
        assertEq(vault.balanceOf(userA), shares, "shares should be minted to user");
        
        // ASSERT: totalAssets reflects deposit
        assertGe(vault.totalAssets(), assets, "totalAssets should be at least deposited amount");
    }
    
    /**
     * @notice Test: first deposit has 1:1 share ratio
     * @dev forge-std assertion: initial shares equal assets
     */
    function test_firstDeposit_oneToOneRatio() public {
        uint256 assets = 100e18;
        
        vm.prank(userA);
        uint256 shares = vault.deposit(assets, userA);
        
        // ASSUME: no prior deposits
        vm.assume(vault.totalAssets() == assets);
        
        // ASSERT: shares ~= assets for first deposit
        assertApproxEqAbs(shares, assets, ABS_TOLERANCE, "first deposit should be ~1:1 shares:assets");
    }
    
    /**
     * @notice Test: redeem returns non-zero assets
     * @dev forge-std assertion: assets > 0 after redeem(shares)
     */
    function test_redeem_returnsNonZeroAssets() public {
        // Setup: deposit first
        uint256 depositAssets = 100e18;
        vm.prank(userA);
        uint256 shares = vault.deposit(depositAssets, userA);
        
        // Redeem
        vm.prank(userA);
        uint256 assets = vault.redeem(shares, userA, userA);
        
        // ASSERT: assets > 0 after redeem
        assertGt(assets, 0, "redeem should return non-zero assets");
        
        // ASSERT: user's share balance is zero
        assertEq(vault.balanceOf(userA), 0, "user shares should be burned");
    }
    
    /**
     * @notice Test: redeem burns shares and transfers assets
     * @dev forge-std assertions: share burning and asset transfer
     */
    function test_redeem_burnsSharesAndTransfersAssets() public {
        // Setup: deposit first
        uint256 depositAssets = 100e18;
        vm.prank(userA);
        uint256 shares = vault.deposit(depositAssets, userA);
        
        uint256 userAssetsBefore = underlying.balanceOf(userA);
        
        // Redeem
        vm.prank(userA);
        uint256 assets = vault.redeem(shares, userA, userA);
        
        // ASSERT: shares were burned
        assertEq(vault.balanceOf(userA), 0, "shares should be burned");
        
        // ASSERT: assets were transferred
        assertEq(
            underlying.balanceOf(userA),
            userAssetsBefore + assets,
            "user should receive assets"
        );
    }
    
    /**
     * @notice Test: round-trip preserves principal
     * @dev forge-std assertion: assetsOut >= principal (no yield scenario)
     *      INVARIANT: User should get at least their principal back
     */
    function test_roundTrip_preservesPrincipal() public {
        uint256 principal = 100e18;
        
        // Deposit
        vm.prank(userA);
        uint256 shares = vault.deposit(principal, userA);
        
        // Redeem immediately (no time for yield)
        vm.prank(userA);
        uint256 assetsOut = vault.redeem(shares, userA, userA);
        
        // ASSERT: assetsOut >= principal (within rounding tolerance)
        assertGe(assetsOut + ABS_TOLERANCE, principal, "user should get at least principal back");
        assertApproxEqAbs(assetsOut, principal, ABS_TOLERANCE, "round-trip should preserve value");
    }
    
    /**
     * @notice Test: convertToShares and convertToAssets are consistent
     * @dev forge-std assertion: conversion round-trip
     *      INVARIANT: convertToAssets(convertToShares(x)) ~= x
     */
    function test_conversions_roundTrip() public {
        // Setup: deposit to establish share price
        vm.prank(userA);
        vault.deposit(100e18, userA);
        
        uint256 testAssets = 50e18;
        
        // Convert assets -> shares -> assets
        uint256 shares = vault.convertToShares(testAssets);
        uint256 assetsBack = vault.convertToAssets(shares);
        
        // ASSERT: round-trip preserves value (within tolerance)
        assertApproxEqAbs(
            assetsBack,
            testAssets,
            ABS_TOLERANCE,
            "conversion round-trip should preserve value"
        );
    }
    
    /**
     * @notice Test: totalAssets reflects deposits
     * @dev forge-std assertion: totalAssets consistency
     *      INVARIANT: totalAssets >= sum of deposits (without withdrawals)
     */
    function test_totalAssets_reflectsDeposits() public {
        uint256 deposit1 = 100e18;
        uint256 deposit2 = 50e18;
        
        // First deposit
        vm.prank(userA);
        vault.deposit(deposit1, userA);
        
        uint256 totalAfterFirst = vault.totalAssets();
        assertGe(totalAfterFirst, deposit1, "totalAssets should cover first deposit");
        
        // Second deposit
        vm.prank(userB);
        vault.deposit(deposit2, userB);
        
        uint256 totalAfterSecond = vault.totalAssets();
        
        // ASSERT: totalAssets >= sum of deposits
        assertGe(totalAfterSecond, deposit1 + deposit2, "totalAssets should cover all deposits");
    }
    
    /**
     * @notice Test: multiple users maintain separate balances
     * @dev forge-std assertion: balance isolation
     *      INVARIANT: User balances are independent
     */
    function test_multipleUsers_maintainSeparateBalances() public {
        uint256 assetsA = 100e18;
        uint256 assetsB = 50e18;
        
        // User A deposits
        vm.prank(userA);
        uint256 sharesA = vault.deposit(assetsA, userA);
        
        // User B deposits
        vm.prank(userB);
        uint256 sharesB = vault.deposit(assetsB, userB);
        
        // ASSERT: balances are separate
        assertEq(vault.balanceOf(userA), sharesA, "user A balance correct");
        assertEq(vault.balanceOf(userB), sharesB, "user B balance correct");
        
        // User A redeems - should not affect User B
        vm.prank(userA);
        vault.redeem(sharesA, userA, userA);
        
        // ASSERT: User B balance unchanged
        assertEq(vault.balanceOf(userB), sharesB, "user B balance unaffected by A's redeem");
    }
    
    /**
     * @notice Fuzz test: deposit never returns zero shares for non-zero assets
     * @dev forge-std assumption + assertion
     */
    function testFuzz_deposit_nonZeroSharesForNonZeroAssets(uint256 assets) public {
        // ASSUME: reasonable deposit amount
        vm.assume(assets > 1000 && assets < 1_000_000e18);
        
        // Fund user
        underlying.mint(userA, assets);
        vm.prank(userA);
        underlying.approve(address(adapter), assets);
        
        // Deposit
        vm.prank(userA);
        uint256 shares = vault.deposit(assets, userA);
        
        // ASSERT: non-zero assets -> non-zero shares
        assertGt(shares, 0, "non-zero assets should yield non-zero shares");
    }
    
    /**
     * @notice Fuzz test: round-trip always preserves principal (within tolerance)
     * @dev forge-std assumption + assertion
     *      INVARIANT: No loss of principal on round-trip
     */
    function testFuzz_roundTrip_preservesPrincipal(uint256 principal) public {
        // ASSUME: reasonable amounts
        vm.assume(principal > 1000 && principal < 1_000_000e18);
        
        // Fund user
        underlying.mint(userA, principal);
        vm.prank(userA);
        underlying.approve(address(adapter), principal);
        
        // Deposit
        vm.prank(userA);
        uint256 shares = vault.deposit(principal, userA);
        
        // Redeem
        vm.prank(userA);
        uint256 assetsOut = vault.redeem(shares, userA, userA);
        
        // ASSERT: assetsOut >= principal (within small tolerance for rounding)
        assertGe(assetsOut + ABS_TOLERANCE, principal, "should preserve principal");
    }
}
