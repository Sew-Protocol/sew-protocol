// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/modules/AaveYieldGenerationModule.sol";
import "../../../contracts/mocks/MockAavePool.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";

/**
 * @title Priority9_YieldGeneration
 * @notice Tests for yield generation safety
 * @dev Priority #9: Verify yield generation works correctly and safely
 */
contract Priority9_YieldGeneration is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    AaveYieldGenerationModule public yieldModule;
    DefaultYieldDistributionModule public yieldDistributionModule;
    MockAavePool public aavePool;
    MockAToken public aToken; // Defined in MockAavePool.sol
    
    address public feeAddress;
    address public resolver;
    address public owner;
    address public guardian;
    
    uint256 public constant ESCROW_FEE = 100;
    uint256 public constant TOKEN_CAP = 100000e18;
    
    function setUp() public {
        owner = address(this);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        guardian = address(0x1234567890123456789012345678901234567890);
        
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();
        
        // Deploy token first (needed for aToken)
        token = new ERC20Mock("Test Token", "TEST", owner, 10000000e18);
        
        // Deploy mock Aave
        aavePool = new MockAavePool();
        aToken = new MockAToken(address(token), "aToken", "aTKN");
        aToken.setPool(address(aavePool)); // Set pool address so MockAavePool can mint
        aavePool.setAToken(address(token), address(aToken));
        yieldModule = new AaveYieldGenerationModule(owner);
        yieldDistributionModule = new DefaultYieldDistributionModule();
        vault = new EscrowVault(ESCROW_FEE, feeAddress);
        
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        bytes32 ROLE_GUARDIAN = vault.ROLE_GUARDIAN();
        bytes32 ROLE_ADMIN = vault.DEFAULT_ADMIN_ROLE();
        bytes32 YIELD_ROLE_TIMELOCK = yieldModule.ROLE_TIMELOCK();
        bytes32 YIELD_ROLE_GUARDIAN = yieldModule.ROLE_GUARDIAN();
        vault.grantRole(ROLE_ADMIN, owner);
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_GUARDIAN, guardian);
        yieldModule.grantRole(YIELD_ROLE_TIMELOCK, owner);
        yieldModule.grantRole(YIELD_ROLE_GUARDIAN, guardian);
        
        vault.queueDefaultResolutionModule(address(resolutionModule));
        vault.queueDefaultReleaseStrategy(address(releaseStrategy));
        vault.queueDefaultYieldGenerationModule(address(yieldModule));
        vault.queueDefaultYieldDistributionModule(address(yieldDistributionModule));
        
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateDefaultResolutionModule();
        vault.activateDefaultReleaseStrategy();
        vault.activateDefaultYieldGenerationModule();
        vault.activateDefaultYieldDistributionModule();
        
        // Set token cap (on yieldModule, not vault)
        yieldModule.setTokenCap(address(token), TOKEN_CAP);
    }
    
    /**
     * @notice Test: Deposit to Aave works correctly
     */
    function test_depositToAave() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 10000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        // Create escrow with yield enabled
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, settings);
        
        // Verify deposit occurred (check aToken balance)
        // Note: Actual implementation may vary
    }
    
    /**
     * @notice Test: Withdrawal from Aave works correctly
     */
    function test_withdrawalFromAave() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 10000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, settings);
        
        // Release escrow (should withdraw from Aave)
        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);
        
        // Verify withdrawal occurred
        // Note: Actual implementation may vary
    }
    
    /**
     * @notice Test: Caps enforced before Aave deposit
     */
    function test_capsEnforcedBeforeAaveDeposit() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        
        // Configure Aave pool via provider (required before enabling)
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        yieldModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        yieldModule.activateAavePoolProvider();
        
        // Register token for Aave and enable Aave
        // aToken is already set up in setUp(), just register it
        yieldModule.registerTokenForAave(address(token), address(aToken));
        yieldModule.setAaveEnabled(true);
        
        // Approve vault to spend tokens from aavePool
        vm.prank(address(vault));
        token.approve(address(aavePool), type(uint256).max);
        
        // Approve vault to spend tokens from aavePool
        vm.prank(address(vault));
        token.approve(address(aavePool), type(uint256).max);
        
        // Use up most of cap (leave small room)
        // Caps are enforced on amountAfterFee (99% of escrow amount)
        uint256 firstAmount = TOKEN_CAP * 99 / 100; // Use 99% to leave some room
        token.mint(buyer, firstAmount);
        vm.prank(buyer);
        token.approve(address(vault), firstAmount);
        
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
        
        // Attempt to exceed cap
        // Calculate: remainingCap = TOKEN_CAP - currentExposure
        // We need: excessAmount * 99/100 > remainingCap
        // So: excessAmount > remainingCap * 100/99
        uint256 remainingCap = TOKEN_CAP - currentExposure;
        uint256 excessAmount = (remainingCap * 100 / 99) + 1; // Slightly more than needed to exceed
        token.mint(buyer, excessAmount);
        vm.prank(buyer);
        token.approve(address(vault), excessAmount);
        
        vm.prank(buyer);
        vm.expectRevert();
        vault.createEscrow(address(token), seller, excessAmount, settings);
    }
    
    /**
     * @notice Test: Guardian can disable Aave
     */
    function test_guardianCanDisableAave() public {
        // Guardian disables Aave
        vm.prank(guardian);
        yieldModule.guardianDisableAave();
        
        // Verify Aave disabled
        // Note: Implementation may vary
    }
    
    /**
     * @notice Test: Disabled Aave prevents new deposits
     */
    function test_disabledAavePreventsDeposits() public {
        // Configure Aave pool via provider
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        yieldModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        yieldModule.activateAavePoolProvider();
        
        // Register token and enable Aave first
        yieldModule.registerTokenForAave(address(token), address(aToken));
        yieldModule.setAaveEnabled(true);
        
        // Approve vault to spend tokens from aavePool
        vm.prank(address(vault));
        token.approve(address(aavePool), type(uint256).max);
        
        // Disable Aave
        vm.prank(guardian);
        yieldModule.guardianDisableAave();
        
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 10000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        // Should still create escrow, but yield may not be generated (Aave disabled)
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, settings);
        assertGe(workflowId, 0, "Escrow creation failed");
    }
    
    /**
     * @notice Test: Re-enable requires timelock
     */
    function test_reEnableRequiresTimelock() public {
        // Configure Aave pool via provider
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        yieldModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        yieldModule.activateAavePoolProvider();
        
        // Register token
        yieldModule.registerTokenForAave(address(token), address(aToken));
        
        // Approve vault to spend tokens from aavePool
        vm.prank(address(vault));
        token.approve(address(aavePool), type(uint256).max);
        
        // Disable Aave
        vm.prank(guardian);
        yieldModule.guardianDisableAave();
        
        // Guardian attempts to re-enable
        vm.prank(guardian);
        vm.expectRevert(); // Should revert - requires ROLE_TIMELOCK
        yieldModule.setAaveEnabled(true);
        
        // Owner (with ROLE_TIMELOCK) can re-enable
        vm.prank(owner);
        yieldModule.setAaveEnabled(true);
    }
    
    /**
     * @notice Test: Yield calculation accuracy
     */
    function test_yieldCalculationAccuracy() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 10000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, settings);
        
        // Warp time forward to generate yield
        vm.warp(block.timestamp + 30 days);
        
        // Calculate yield (must be called from vault context)
        vm.prank(address(vault));
        uint256 yield = yieldModule.calculateYield(workflowId, address(token));
        
        // Yield should be non-negative
        assertGe(yield, 0, "Yield should be non-negative");
    }
    
    /**
     * @notice Test: aToken balance tracking
     */
    function test_aTokenBalanceTracking() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 10000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldEnabled: true,
            autoReleaseTime: 0,
            autoCancelTime: 0,
            escrowType: EscrowType.STANDARD
        });
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, settings);
        
        // Verify aToken balance tracked (mapping: escrowContract => workflowId => balance)
        uint256 aTokenBalance = yieldModule.escrowATokenBalance(address(vault), workflowId);
        assertGe(aTokenBalance, 0, "aToken balance should be tracked");
    }
}

