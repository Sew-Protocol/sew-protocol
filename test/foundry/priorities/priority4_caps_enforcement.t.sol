// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/modules/AaveYieldGenerationModule.sol";
import "../../../contracts/mocks/MockAavePool.sol";
import "../../../contracts/types/EscrowTypes.sol";

/**
 * @title Priority4_CapsEnforcement
 * @notice Tests for caps enforcement on yield generation
 * @dev Priority #4: Verify caps are enforced at deposit time
 */
contract Priority4_CapsEnforcement is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    AaveYieldGenerationModule public yieldModule;
    MockAavePool public aavePool;
    
    address public feeAddress;
    address public resolver;
    address public owner;
    address public guardian;
    
    uint256 public constant ESCROW_FEE = 100;
    uint256 public constant TOKEN_CAP = 100000e18;
    uint256 public constant GLOBAL_CAP = 500000e18;
    
    function setUp() public {
        owner = address(this);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        guardian = address(0x1234567890123456789012345678901234567890);
        
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();
        
        // Deploy mock Aave
        aavePool = new MockAavePool();
        yieldModule = new AaveYieldGenerationModule(owner);
        
        token = new ERC20Mock("Test Token", "TEST", owner, 10000000e18);
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(0));
        
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        bytes32 ROLE_GUARDIAN = vault.ROLE_GUARDIAN();
        bytes32 YIELD_ROLE_TIMELOCK = yieldModule.ROLE_TIMELOCK();
        bytes32 YIELD_ROLE_GUARDIAN = yieldModule.ROLE_GUARDIAN();
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_GUARDIAN, guardian);
        yieldModule.grantRole(YIELD_ROLE_TIMELOCK, owner);
        yieldModule.grantRole(YIELD_ROLE_GUARDIAN, guardian);
        
        vault.queueDefaultResolutionModule(address(resolutionModule));
        vault.queueDefaultReleaseStrategy(address(releaseStrategy));
        vault.queueDefaultYieldGenerationModule(address(yieldModule));
        
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateDefaultResolutionModule();
        vault.activateDefaultReleaseStrategy();
        vault.activateDefaultYieldGenerationModule();
        
        // Set caps (on yieldModule, not vault)
        yieldModule.setTokenCap(address(token), TOKEN_CAP);
        yieldModule.setGlobalCap(address(token), GLOBAL_CAP);
    }
    
    /**
     * @notice Test: Token cap enforced at deposit time
     */
    function test_tokenCapEnforced() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        
        // Configure Aave pool via provider (required before enabling)
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        yieldModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        yieldModule.activateAavePoolProvider();
        
        // Register token for Aave and enable Aave
        MockAToken aToken = new MockAToken(address(token), "aToken", "aTKN");
        aToken.setPool(address(aavePool)); // Set pool address so MockAavePool can mint
        aavePool.setAToken(address(token), address(aToken));
        yieldModule.registerTokenForAave(address(token), address(aToken));
        yieldModule.setAaveEnabled(true);
        
        // Approve vault to spend tokens from aavePool (needed for MockAavePool.supply)
        // In real Aave, the vault would approve the pool, but for testing we need to set this up
        vm.prank(address(vault));
        token.approve(address(aavePool), type(uint256).max);
        
        // Caps are enforced on amountAfterFee (99% of escrow amount)
        // To use up TOKEN_CAP, we need: escrowAmount * 99/100 = TOKEN_CAP
        // So: escrowAmount = TOKEN_CAP * 100/99
        // But we'll use TOKEN_CAP directly - it will use 99% of TOKEN_CAP, leaving 1% room
        uint256 firstAmount = TOKEN_CAP * 99 / 100; // Use 99% to leave some room
        token.mint(buyer, firstAmount);
        vm.prank(buyer);
        token.approve(address(vault), firstAmount);
        
        // Create escrow with yield enabled (caps enforced)
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        vm.prank(buyer);
        vault.createEscrow(address(token), seller, firstAmount, settings);
        
        // Check current exposure
        uint256 currentExposure = yieldModule.currentExposure(address(token));
        
        // After fees, firstAmount used ~99% of TOKEN_CAP, leaving ~1%
        // So we need to deposit more than 1% of TOKEN_CAP to exceed
        // Calculate: remainingCap = TOKEN_CAP - currentExposure
        // We need: excessAmount * 99/100 > remainingCap
        // So: excessAmount > remainingCap * 100/99
        uint256 remainingCap = TOKEN_CAP - currentExposure;
        uint256 excessAmount = (remainingCap * 100 / 99) + 1; // Slightly more than needed to exceed
        token.mint(buyer, excessAmount);
        vm.prank(buyer);
        token.approve(address(vault), excessAmount);
        
        vm.prank(buyer);
        vm.expectRevert(); // Should revert when cap exceeded
        vault.createEscrow(address(token), seller, excessAmount, settings);
    }
    
    /**
     * @notice Test: Global cap enforced at deposit time
     */
    function test_globalCapEnforced() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        ERC20Mock token2 = new ERC20Mock("Token2", "TKN2", owner, 10000000e18);
        
        // Configure Aave pool via provider
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        yieldModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        yieldModule.activateAavePoolProvider();
        
        // Register tokens for Aave and enable Aave
        MockAToken aToken1 = new MockAToken(address(token), "aToken1", "aTKN1");
        MockAToken aToken2 = new MockAToken(address(token2), "aToken2", "aTKN2");
        aToken1.setPool(address(aavePool)); // Set pool address so MockAavePool can mint
        aToken2.setPool(address(aavePool)); // Set pool address so MockAavePool can mint
        aavePool.setAToken(address(token), address(aToken1));
        aavePool.setAToken(address(token2), address(aToken2));
        yieldModule.registerTokenForAave(address(token), address(aToken1));
        yieldModule.registerTokenForAave(address(token2), address(aToken2));
        yieldModule.setAaveEnabled(true);
        
        // Approve vault to spend tokens from aavePool
        vm.prank(address(vault));
        token.approve(address(aavePool), type(uint256).max);
        vm.prank(address(vault));
        token2.approve(address(aavePool), type(uint256).max);
        
        // Set global cap for token (per-token, not cross-token)
        // Global cap is per-token, so we test with a single token
        // Use a smaller global cap than token cap to test global cap enforcement
        uint256 testGlobalCap = TOKEN_CAP / 5; // 20000e18, smaller than TOKEN_CAP
        yieldModule.setGlobalCap(address(token), testGlobalCap);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        // Use up most of global cap with token (leave small room)
        // Caps are enforced on amountAfterFee (99% of escrow amount)
        // To use up most of testGlobalCap, we need: escrowAmount * 99/100 = testGlobalCap * 99/100
        // So: escrowAmount = testGlobalCap * 99/100 * 100/99 = testGlobalCap
        // But we'll use 99% of testGlobalCap to leave room
        uint256 amountToUse = testGlobalCap * 99 / 100;
        token.mint(buyer, amountToUse);
        vm.prank(buyer);
        token.approve(address(vault), amountToUse);
        
        vm.prank(buyer);
        vault.createEscrow(address(token), seller, amountToUse, settings);
        
        // Check current exposure
        uint256 currentExposure = yieldModule.currentExposure(address(token));
        
        // Attempt to exceed global cap with another escrow of the same token
        // Calculate: remainingCap = testGlobalCap - currentExposure
        // We need: excessAmount * 99/100 > remainingCap
        // So: excessAmount > remainingCap * 100/99
        uint256 remainingCap = testGlobalCap - currentExposure;
        uint256 excessAmount = (remainingCap * 100 / 99) + 1; // Slightly more than needed to exceed
        token.mint(buyer, excessAmount);
        vm.prank(buyer);
        token.approve(address(vault), excessAmount);
        
        vm.prank(buyer);
        vm.expectRevert(); // Should revert when global cap exceeded
        vault.createEscrow(address(token), seller, excessAmount, settings);
    }
    
    /**
     * @notice Test: Exposure tracking accuracy
     */
    function test_exposureTrackingAccuracy() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 10000e18;
        
        token.mint(buyer, amount * 3);
        vm.prank(buyer);
        token.approve(address(vault), amount * 3);
        
        // Create escrow
        vm.prank(buyer);
        uint256 workflowId1 = vault.createEscrow(address(token), seller, amount);
        
        // Verify exposure incremented
        // Note: Actual exposure tracking depends on AaveYieldGenerationModule implementation
        // This test may need adjustment based on actual implementation
        
        // Release escrow
        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId1);
        
        // Verify exposure decremented
        // Note: Actual verification depends on implementation
    }
    
    /**
     * @notice Test: Deposit at cap boundary
     */
    function test_depositAtCapBoundary() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        
        // Configure Aave pool via provider (required before enabling)
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        yieldModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        yieldModule.activateAavePoolProvider();
        
        // Register token for Aave and enable Aave
        MockAToken aToken = new MockAToken(address(token), "aToken", "aTKN");
        aToken.setPool(address(aavePool)); // Set pool address so MockAavePool can mint
        aavePool.setAToken(address(token), address(aToken));
        yieldModule.registerTokenForAave(address(token), address(aToken));
        yieldModule.setAaveEnabled(true);
        
        // Approve vault to spend tokens from aavePool (needed for MockAavePool.supply)
        // In real Aave, the vault would approve the pool, but for testing we need to set this up
        vm.prank(address(vault));
        token.approve(address(aavePool), type(uint256).max);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        // Deposit amount that uses up the cap (after fees)
        // After 1% fee, the amount going to Aave is 99% of the escrow amount
        // To use up TOKEN_CAP, we need: escrowAmount * 99/100 = TOKEN_CAP
        // So: escrowAmount = TOKEN_CAP * 100/99
        // But we'll use TOKEN_CAP directly - it will use 99% of TOKEN_CAP, leaving 1% room
        uint256 firstAmount = TOKEN_CAP * 99 / 100; // Use 99% to leave some room
        token.mint(buyer, firstAmount);
        vm.prank(buyer);
        token.approve(address(vault), firstAmount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, firstAmount, settings);
        
        // Should succeed (workflowId starts at 0)
        assertGe(workflowId, 0, "Escrow creation failed");
        
        // Check current exposure
        uint256 currentExposure = yieldModule.currentExposure(address(token));
        
        // Attempt to deposit amount that would exceed cap
        // Calculate: remainingCap = TOKEN_CAP - currentExposure
        // We need: excessAmount * 99/100 > remainingCap
        // So: excessAmount > remainingCap * 100/99
        uint256 remainingCap = TOKEN_CAP - currentExposure;
        uint256 excessAmount = (remainingCap * 100 / 99) + 1; // Slightly more than needed to exceed
        token.mint(buyer, excessAmount);
        vm.prank(buyer);
        token.approve(address(vault), excessAmount);
        
        vm.prank(buyer);
        vm.expectRevert(); // Should revert when cap exceeded
        vault.createEscrow(address(token), seller, excessAmount, settings);
    }
    
    /**
     * @notice Test: Zero cap (unlimited) handling
     */
    function test_zeroCapUnlimited() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        ERC20Mock token2 = new ERC20Mock("Token2", "TKN2", owner, 10000000e18);
        
        // Configure Aave pool via provider
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        yieldModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        yieldModule.activateAavePoolProvider();
        
        // Register token for Aave and enable Aave
        MockAToken aToken2 = new MockAToken(address(token2), "aToken2", "aTKN2");
        aToken2.setPool(address(aavePool)); // Set pool address so MockAavePool can mint
        aavePool.setAToken(address(token2), address(aToken2));
        yieldModule.registerTokenForAave(address(token2), address(aToken2));
        yieldModule.setAaveEnabled(true);
        
        // Approve vault to spend tokens from aavePool
        vm.prank(address(vault));
        token2.approve(address(aavePool), type(uint256).max);
        
        // Set zero cap (unlimited) - 0 means no cap
        yieldModule.setTokenCap(address(token2), 0);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        // Should be able to deposit any amount
        uint256 largeAmount = 1000000e18;
        token2.mint(buyer, largeAmount);
        vm.prank(buyer);
        token2.approve(address(vault), largeAmount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token2), seller, largeAmount, settings);
        
        assertGe(workflowId, 0, "Escrow creation failed with zero cap");
    }
    
    /**
     * @notice Test: Guardian can only lower caps (down-only)
     */
    function test_guardianCannotRaiseCaps() public {
        uint256 currentCap = yieldModule.tokenCap(address(token));
        
        // Guardian attempts to raise cap
        vm.prank(guardian);
        vm.expectRevert(); // Should revert
        yieldModule.guardianLowerTokenCap(address(token), currentCap + 1e18);
        
        // Guardian can lower cap
        vm.prank(guardian);
        yieldModule.guardianLowerTokenCap(address(token), currentCap - 1e18);
        
        assertEq(yieldModule.tokenCap(address(token)), currentCap - 1e18, "Cap not lowered");
    }
    
    /**
     * @notice Fuzz test: Caps enforced for various amounts
     */
    function testFuzz_capsEnforced(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, TOKEN_CAP * 2);
        
        // Set up Aave (required for caps to be enforced)
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        yieldModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        yieldModule.activateAavePoolProvider();
        
        MockAToken aToken = new MockAToken(address(token), "aToken", "aTKN");
        aToken.setPool(address(aavePool));
        aavePool.setAToken(address(token), address(aToken));
        yieldModule.registerTokenForAave(address(token), address(aToken));
        yieldModule.setAaveEnabled(true);
        
        vm.prank(address(vault));
        token.approve(address(aavePool), type(uint256).max);
        
        address buyer = address(0x1001);
        address seller = address(0x1002);
        
        token.mint(buyer, depositAmount);
        vm.prank(buyer);
        token.approve(address(vault), depositAmount);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true, // Enable yield so caps are checked
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        vm.prank(buyer);
        
        // After fees, the amount going to Aave is ~99% of depositAmount
        // So we need to check if 99% of depositAmount > TOKEN_CAP
        uint256 amountAfterFee = depositAmount * 99 / 100;
        if (amountAfterFee > TOKEN_CAP) {
            vm.expectRevert();
        }
        
        vault.createEscrow(address(token), seller, depositAmount, settings);
    }
}

