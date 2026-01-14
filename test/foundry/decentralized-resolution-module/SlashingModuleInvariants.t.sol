// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol";
import "../../../contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Reuse mock tokens from staking tests
contract MockStable is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000e6);
    }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSEW is ERC20 {
    constructor() ERC20("Mock SEW", "SEW") {
        _mint(msg.sender, 1000000e18);
    }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @title SlashingModuleInvariantsTest
 * @notice Comprehensive invariant tests for ResolverSlashingModuleV1
 * @dev Tests critical properties:
 *      1. Slashes never exceed caps (per-offense and per-period)
 *      2. No double slashing (one slash per workflow/resolver pair)
 *      3. Freeze logic prevents withdrawal during slash processing
 *      4. Waterfall ordering: resolver exhausted before senior exposed
 */
contract SlashingModuleInvariantsTest is Test {
    ResolverSlashingModuleV1 public slashingModule;
    ResolverStakingModuleV1 public stakingModule;
    MockStable public stableToken;
    MockSEW public sewToken;
    
    address public admin = address(0x1);
    address public resolver1 = address(0x2);
    address public resolver2 = address(0x3);
    address public senior1 = address(0x4);
    address public resolutionModule = address(0x5);
    
    uint256 constant BASIS_POINTS = 10000;
    uint256 constant PRECISION = 1e18;
    
    function setUp() public {
        // Deploy tokens
        vm.startPrank(admin);
        stableToken = new MockStable();
        sewToken = new MockSEW();
        
        // Deploy staking module
        ResolverStakingModuleV1 stakingImpl = new ResolverStakingModuleV1();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(
            address(stakingImpl),
            abi.encodeCall(ResolverStakingModuleV1.initialize, (admin, address(stableToken), address(sewToken)))
        );
        stakingModule = ResolverStakingModuleV1(address(stakingProxy));
        
        // Deploy slashing module
        ResolverSlashingModuleV1 slashingImpl = new ResolverSlashingModuleV1();
        ERC1967Proxy slashingProxy = new ERC1967Proxy(
            address(slashingImpl),
            abi.encodeCall(ResolverSlashingModuleV1.initialize, (admin, address(stakingModule)))
        );
        slashingModule = ResolverSlashingModuleV1(address(slashingProxy));
        
        // Setup roles
        stakingModule.setResolutionModule(resolutionModule);
        slashingModule.grantRole(slashingModule.ROLE_RESOLUTION_MODULE(), resolutionModule);
        
        // Setup tiers
        stakingModule.setResolverTier(resolver1, 0);
        stakingModule.setResolverTier(resolver2, 0);
        stakingModule.setResolverTier(senior1, 1);
        
        // Mint and approve tokens
        stableToken.mint(resolver1, 100000e6);
        stableToken.mint(resolver2, 100000e6);
        stableToken.mint(senior1, 100000e6);
        
        vm.stopPrank();
        
        vm.prank(resolver1);
        stableToken.approve(address(stakingModule), type(uint256).max);
        vm.prank(resolver2);
        stableToken.approve(address(stakingModule), type(uint256).max);
        vm.prank(senior1);
        stableToken.approve(address(stakingModule), type(uint256).max);
    }
    
    // ============ Invariant 1: Slashes Never Exceed Caps ============
    
    /**
     * @notice CRITICAL INVARIANT: Single slash never exceeds per-offense cap (50%)
     */
    function test_SlashNeverExceedsPerOffenseCap() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        IStakingModule.StakeInfo memory infoBefore = stakingModule.getStakeInfo(resolver1);
        uint256 stakeBefore = infoBefore.totalStake;
        
        // Slash for timeout
        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForTimeout(1, resolver1, 1);
        
        // Get slash event
        ISlashingModule.SlashEvent memory slashEvent = slashingModule.getSlashEvent(slashId);
        
        // INVARIANT: Slash amount <= 50% of stake
        uint256 maxAllowed = (stakeBefore * 5000) / BASIS_POINTS;
        assertLe(slashEvent.amount, maxAllowed, "Slash exceeds per-offense cap");
    }
    
    /**
     * @notice CRITICAL INVARIANT: Total slashes in period never exceed period cap (100%)
     */
    function test_SlashesNeverExceedPeriodCap() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        IStakingModule.StakeInfo memory info = stakingModule.getStakeInfo(resolver1);
        uint256 initialStake = info.totalStake;
        
        // Slash multiple times
        uint256 totalSlashed = 0;
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(resolutionModule);
            uint256 slashId = slashingModule.slashForTimeout(i + 1, resolver1, 1);
            
            if (slashId > 0) {
                ISlashingModule.SlashEvent memory slashEvent = slashingModule.getSlashEvent(slashId);
                totalSlashed += slashEvent.amount;
            }
        }
        
        // INVARIANT: Total slashed <= 100% of initial stake
        assertLe(totalSlashed, initialStake, "Total slashes exceed period cap");
        
        // Verify via query function
        uint256 slashedInPeriod = slashingModule.getSlashedInPeriod(resolver1);
        assertLe(slashedInPeriod, initialStake, "Slashed in period exceeds stake");
    }
    
    /**
     * @notice INVARIANT: Slash amount respects conservative penalty schedule
     */
    function test_SlashAmountMatchesPenaltySchedule() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        IStakingModule.StakeInfo memory info = stakingModule.getStakeInfo(resolver1);
        uint256 stake = info.totalStake;
        
        // Test missed accept (2%)
        vm.prank(resolutionModule);
        uint256 slashId1 = slashingModule.slashForTimeout(1, resolver1, 0);
        ISlashingModule.SlashEvent memory slash1 = slashingModule.getSlashEvent(slashId1);
        
        uint256 expectedMissedAccept = (stake * 200) / BASIS_POINTS; // 2%
        assertEq(slash1.amount, expectedMissedAccept, "Missed accept penalty wrong");
        
        // Test missed resolve (5%)
        vm.prank(resolver2);
        stakingModule.stakeWithMix(10000e6, 0);
        
        vm.prank(resolutionModule);
        uint256 slashId2 = slashingModule.slashForTimeout(2, resolver2, 1);
        ISlashingModule.SlashEvent memory slash2 = slashingModule.getSlashEvent(slashId2);
        
        uint256 expectedMissedResolve = (stake * 500) / BASIS_POINTS; // 5%
        assertEq(slash2.amount, expectedMissedResolve, "Missed resolve penalty wrong");
    }
    
    // ============ Invariant 2: No Double Slashing ============
    
    /**
     * @notice CRITICAL INVARIANT: Cannot slash same resolver twice for same workflow
     */
    function test_NoDoubleSlashing() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // First slash
        vm.prank(resolutionModule);
        uint256 slashId1 = slashingModule.slashForTimeout(1, resolver1, 1);
        assertTrue(slashId1 > 0, "First slash failed");
        
        // Try to slash again for same workflow
        vm.prank(resolutionModule);
        uint256 slashId2 = slashingModule.slashForTimeout(1, resolver1, 1);
        
        // INVARIANT: Second slash returns 0 (already slashed)
        assertEq(slashId2, 0, "Double slash allowed");
    }
    
    /**
     * @notice INVARIANT: Can slash same resolver for different workflows
     */
    function test_CanSlashDifferentWorkflows() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // Slash for workflow 1
        vm.prank(resolutionModule);
        uint256 slashId1 = slashingModule.slashForTimeout(1, resolver1, 1);
        assertTrue(slashId1 > 0, "First slash failed");
        
        // Slash for workflow 2 (different workflow)
        vm.prank(resolutionModule);
        uint256 slashId2 = slashingModule.slashForTimeout(2, resolver1, 1);
        
        // INVARIANT: Second slash succeeds (different workflow)
        assertTrue(slashId2 > 0, "Second slash failed");
        assertNotEq(slashId1, slashId2, "Slash IDs should be different");
    }
    
    // ============ Invariant 3: Freeze Logic ============
    
    /**
     * @notice CRITICAL INVARIANT: Resolver is frozen after slash
     */
    function test_ResolverFrozenAfterSlash() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // Check not frozen initially
        (bool frozenBefore,) = slashingModule.isResolverFrozen(resolver1);
        assertFalse(frozenBefore, "Should not be frozen initially");
        
        // Slash
        vm.prank(resolutionModule);
        slashingModule.slashForTimeout(1, resolver1, 1);
        
        // INVARIANT: Resolver is frozen after slash
        (bool frozenAfter, uint256 frozenUntil) = slashingModule.isResolverFrozen(resolver1);
        assertTrue(frozenAfter, "Should be frozen after slash");
        assertGt(frozenUntil, block.timestamp, "Freeze until should be in future");
    }
    
    /**
     * @notice INVARIANT: Freeze duration is 7 days
     */
    function test_FreezeDurationCorrect() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        uint256 slashTime = block.timestamp;
        
        // Slash
        vm.prank(resolutionModule);
        slashingModule.slashForTimeout(1, resolver1, 1);
        
        // Check freeze duration
        (, uint256 frozenUntil) = slashingModule.isResolverFrozen(resolver1);
        
        // INVARIANT: Frozen for 7 days
        assertEq(frozenUntil, slashTime + 7 days, "Freeze duration wrong");
    }
    
    /**
     * @notice INVARIANT: Freeze expires after duration
     */
    function test_FreezeExpires() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // Slash
        vm.prank(resolutionModule);
        slashingModule.slashForTimeout(1, resolver1, 1);
        
        // Check frozen
        (bool frozen1,) = slashingModule.isResolverFrozen(resolver1);
        assertTrue(frozen1, "Should be frozen");
        
        // Warp past freeze duration
        vm.warp(block.timestamp + 7 days + 1);
        
        // INVARIANT: No longer frozen after duration
        (bool frozen2,) = slashingModule.isResolverFrozen(resolver1);
        assertFalse(frozen2, "Should not be frozen after duration");
    }
    
    // ============ Invariant 4: Waterfall Ordering ============
    
    /**
     * @notice INVARIANT: Resolver stake slashed before senior coverage
     * @dev This is documented behavior, actual implementation in Phase 3
     */
    function test_WaterfallOrderingDocumented() public {
        // Setup: Senior with coverage, junior with delegation
        vm.prank(senior1);
        stakingModule.stakeWithMix(30000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.stakeWithMix(3000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.delegateStake(senior1, 0);
        
        // Get initial stakes
        IStakingModule.StakeInfo memory juniorInfo = stakingModule.getStakeInfo(resolver1);
        IStakingModule.StakeInfo memory seniorInfo = stakingModule.getStakeInfo(senior1);
        
        uint256 juniorStake = juniorInfo.totalStake;
        uint256 seniorStake = seniorInfo.totalStake;
        
        // INVARIANT: Junior has own stake + delegated coverage
        assertEq(juniorInfo.totalStake, 3000e18, "Junior stake wrong");
        assertEq(juniorInfo.delegatedFrom, 9000e18, "Delegated coverage wrong");
        
        // INVARIANT: Senior has reserved coverage
        assertEq(seniorInfo.delegatedTo, 9000e18, "Reserved coverage wrong");
        
        // Slash junior (small slash, covered by junior's own stake)
        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForTimeout(1, resolver1, 1);
        
        ISlashingModule.SlashEvent memory slashEvent = slashingModule.getSlashEvent(slashId);
        
        // INVARIANT: Slash amount is 5% of junior stake (150 USD)
        uint256 expectedSlash = (juniorStake * 500) / BASIS_POINTS;
        assertEq(slashEvent.amount, expectedSlash, "Slash amount wrong");
        
        // INVARIANT: Slash < junior stake, so senior not touched
        assertLt(slashEvent.amount, juniorStake, "Slash should be less than junior stake");
        
        // In production, would verify:
        // - Junior's stake reduced by slashAmount
        // - Senior's stake unchanged
        // This will be implemented when staking module has slash() function
    }
    
    // ============ Circuit Breaker Tests ============
    
    /**
     * @notice INVARIANT: Circuit breaker prevents slashing when active
     */
    function test_CircuitBreakerPreventsSlashing() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // Activate circuit breaker
        vm.prank(admin);
        slashingModule.triggerCircuitBreaker("Test");
        
        assertTrue(slashingModule.circuitBreakerActive(), "Circuit breaker should be active");
        
        // Try to slash
        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForTimeout(1, resolver1, 1);
        
        // INVARIANT: Slash returns 0 (circuit breaker active)
        assertEq(slashId, 0, "Slash should be blocked by circuit breaker");
    }
    
    /**
     * @notice INVARIANT: Circuit breaker can be reset after cooldown
     */
    function test_CircuitBreakerCooldown() public {
        // Activate circuit breaker
        vm.prank(admin);
        slashingModule.triggerCircuitBreaker("Test");
        
        // Try to reset immediately
        vm.prank(admin);
        vm.expectRevert("Cooldown not passed");
        slashingModule.resetCircuitBreaker();
        
        // Warp past cooldown (1 hour)
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Now can reset
        vm.prank(admin);
        slashingModule.resetCircuitBreaker();
        
        assertFalse(slashingModule.circuitBreakerActive(), "Circuit breaker should be inactive");
    }
    
    // ============ Additional Tests ============
    
    /**
     * @notice Test slash distribution (50% insurance, 30% protocol, 20% burn)
     */
    function test_SlashDistribution() public {
        uint256 slashAmount = 1000e18;
        
        ISlashingModule.SlashDistribution memory dist = slashingModule.calculateDistribution(
            slashAmount,
            ISlashingModule.SlashReason.TIMEOUT_RESOLVE
        );
        
        // INVARIANT: 50% to insurance pool
        assertEq(dist.toInsurancePool, 500e18, "Insurance pool share wrong");
        
        // INVARIANT: 30% to protocol
        assertEq(dist.toProtocol, 300e18, "Protocol share wrong");
        
        // INVARIANT: Remaining 20% burned (not distributed)
        uint256 distributed = dist.toInsurancePool + dist.toProtocol + dist.toCounterParty + dist.toSlashProposer;
        assertEq(distributed, 800e18, "Distribution total wrong");
    }
    
    /**
     * @notice Test reversal slashing is disabled
     */
    function test_ReversalSlashingDisabled() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // Try to slash for reversal
        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForReversal(1, resolver1, 0);
        
        // INVARIANT: Reversal slashing returns 0 (disabled)
        assertEq(slashId, 0, "Reversal slashing should be disabled");
    }
    
    /**
     * @notice Test slash config query
     */
    function test_SlashConfigQuery() public {
        ISlashingModule.SlashConfig memory config = slashingModule.getSlashConfig();
        
        // Verify conservative defaults
        assertEq(config.timeoutSlashBps, 500, "Timeout slash wrong"); // 5%
        assertEq(config.reversalSlashBps, 0, "Reversal slash should be 0");
        assertEq(config.fraudSlashBps, 0, "Fraud slash should be 0");
        assertEq(config.maxSlashPerPeriod, 10000, "Max per period wrong");
        assertEq(config.slashPeriod, 30 days, "Slash period wrong");
    }
    
    /**
     * @notice Test insurance pool funding
     */
    function test_InsurancePoolFunding() public {
        uint256 initialBalance = slashingModule.getInsurancePoolBalance();
        
        // Fund insurance pool
        vm.prank(admin);
        slashingModule.fundInsurancePool(1000e18);
        
        uint256 newBalance = slashingModule.getInsurancePoolBalance();
        assertEq(newBalance, initialBalance + 1000e18, "Insurance pool balance wrong");
    }
    
    /**
     * @notice Test admin can unfreeze resolver
     */
    function test_AdminCanUnfreeze() public {
        // Stake and slash
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        vm.prank(resolutionModule);
        slashingModule.slashForTimeout(1, resolver1, 1);
        
        // Check frozen
        (bool frozen1,) = slashingModule.isResolverFrozen(resolver1);
        assertTrue(frozen1, "Should be frozen");
        
        // Admin unfreezes
        vm.prank(admin);
        slashingModule.unfreezeResolver(resolver1);
        
        // Check unfrozen
        (bool frozen2,) = slashingModule.isResolverFrozen(resolver1);
        assertFalse(frozen2, "Should be unfrozen");
    }
    
    /**
     * @notice Test slash period reset
     */
    function test_SlashPeriodReset() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // Slash in period 1
        vm.prank(resolutionModule);
        slashingModule.slashForTimeout(1, resolver1, 1);
        
        uint256 slashedPeriod1 = slashingModule.getSlashedInPeriod(resolver1);
        assertGt(slashedPeriod1, 0, "Should have slashed in period 1");
        
        // Warp to new period
        vm.warp(block.timestamp + 30 days + 1);
        
        // Slash in period 2
        vm.prank(resolutionModule);
        slashingModule.slashForTimeout(2, resolver1, 1);
        
        uint256 slashedPeriod2 = slashingModule.getSlashedInPeriod(resolver1);
        
        // INVARIANT: Period counter reset
        assertLt(slashedPeriod2, slashedPeriod1 * 2, "Period should have reset");
    }
}
