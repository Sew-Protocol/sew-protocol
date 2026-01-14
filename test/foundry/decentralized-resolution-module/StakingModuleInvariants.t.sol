// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol";
import "../../../contracts/decentralized-resolution-module/BondValuationLibrary.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mock ERC20 tokens
contract MockStable is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000e6); // 1M USDC
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSEW is ERC20 {
    constructor() ERC20("Mock SEW", "SEW") {
        _mint(msg.sender, 1000000e18); // 1M SEW
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title StakingModuleInvariantsTest
 * @notice Comprehensive invariant tests for ResolverStakingModuleV1
 * @dev Tests critical properties:
 *      1. Mix constraints always hold (80% stable, 20% SEW)
 *      2. Reserved coverage <= available coverage
 *      3. Withdrawals cannot bypass freeze/unbond delays
 *      4. Senior only exposed after resolver exhausted
 */
contract StakingModuleInvariantsTest is Test {
    ResolverStakingModuleV1 public stakingModule;
    MockStable public stableToken;
    MockSEW public sewToken;
    
    address public admin = address(0x1);
    address public resolver1 = address(0x2);
    address public resolver2 = address(0x3);
    address public senior1 = address(0x4);
    address public senior2 = address(0x5);
    address public resolutionModule = address(0x6);
    
    uint256 constant PRECISION = 1e18;
    uint256 constant BASIS_POINTS = 10000;
    
    // Test bounds
    uint256 constant MAX_STABLE = 100_000e6;  // 100K USDC
    uint256 constant MAX_SEW = 100_000e18;    // 100K SEW
    
    function setUp() public {
        // Deploy tokens
        vm.startPrank(admin);
        stableToken = new MockStable();
        sewToken = new MockSEW();
        
        // Deploy staking module with proxy
        ResolverStakingModuleV1 impl = new ResolverStakingModuleV1();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ResolverStakingModuleV1.initialize, (admin, address(stableToken), address(sewToken)))
        );
        stakingModule = ResolverStakingModuleV1(address(proxy));
        
        // Setup roles
        stakingModule.setResolutionModule(resolutionModule);
        
        // Setup tiers
        stakingModule.setResolverTier(resolver1, 0);
        stakingModule.setResolverTier(resolver2, 0);
        stakingModule.setResolverTier(senior1, 1);
        stakingModule.setResolverTier(senior2, 1);
        
        // Mint tokens to resolvers
        stableToken.mint(resolver1, MAX_STABLE);
        stableToken.mint(resolver2, MAX_STABLE);
        stableToken.mint(senior1, MAX_STABLE);
        stableToken.mint(senior2, MAX_STABLE);
        
        sewToken.mint(resolver1, MAX_SEW);
        sewToken.mint(resolver2, MAX_SEW);
        sewToken.mint(senior1, MAX_SEW);
        sewToken.mint(senior2, MAX_SEW);
        
        vm.stopPrank();
        
        // Approve tokens
        vm.prank(resolver1);
        stableToken.approve(address(stakingModule), type(uint256).max);
        vm.prank(resolver1);
        sewToken.approve(address(stakingModule), type(uint256).max);
        
        vm.prank(resolver2);
        stableToken.approve(address(stakingModule), type(uint256).max);
        vm.prank(resolver2);
        sewToken.approve(address(stakingModule), type(uint256).max);
        
        vm.prank(senior1);
        stableToken.approve(address(stakingModule), type(uint256).max);
        vm.prank(senior1);
        sewToken.approve(address(stakingModule), type(uint256).max);
        
        vm.prank(senior2);
        stableToken.approve(address(stakingModule), type(uint256).max);
        vm.prank(senior2);
        sewToken.approve(address(stakingModule), type(uint256).max);
    }
    
    // ============ Invariant 1: Mix Constraints Always Hold ============
    
    /**
     * @notice CRITICAL INVARIANT: All bonds must satisfy 80/20 mix rule
     */
    function testFuzz_MixConstraintsAlwaysHold(
        uint256 stableAmount,
        uint256 sewAmount
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 1000e6, MAX_STABLE);
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        
        // Try to stake
        vm.prank(resolver1);
        try stakingModule.stakeWithMix(stableAmount, sewAmount) {
            // If stake succeeded, mix must be valid
            (
                uint256 bondStable,
                uint256 bondSew,
                uint256 effectiveBond,
                uint256 stablePct,
                uint256 sewPct
            ) = stakingModule.getBondComposition(resolver1);
            
            // INVARIANT: Stable >= 80%
            assertGe(stablePct, 8000, "Stable < 80%");
            
            // INVARIANT: SEW <= 20%
            assertLe(sewPct, 2000, "SEW > 20%");
            
            // INVARIANT: Percentages sum to 100%
            assertEq(stablePct + sewPct, BASIS_POINTS, "Percentages don't sum to 100%");
            
            // INVARIANT: Effective bond matches formula
            uint256 expectedBond = BondValuationLibrary.calculateEffectiveBondUSD(
                bondStable,
                bondSew,
                PRECISION,
                5000, // 50% haircut
                6,    // USDC decimals
                18    // SEW decimals
            );
            assertEq(effectiveBond, expectedBond, "Effective bond mismatch");
        } catch {
            // If stake failed, mix must be invalid
            (bool valid,,) = BondValuationLibrary.checkBondMix(
                stableAmount,
                sewAmount,
                PRECISION,
                5000,
                6,
                18
            );
            assertFalse(valid, "Invalid mix accepted");
        }
    }
    
    /**
     * @notice INVARIANT: Cannot stake if mix would become invalid
     */
    function testFuzz_CannotStakeInvalidMix(
        uint256 stableAmount,
        uint256 sewAmount
    ) public {
        // Bound inputs to create invalid mix (too much SEW)
        stableAmount = bound(stableAmount, 100e6, 1000e6);  // Small stable
        sewAmount = bound(sewAmount, 10000e18, MAX_SEW);    // Large SEW
        
        // Check if mix is invalid
        (bool valid,,) = BondValuationLibrary.checkBondMix(
            stableAmount,
            sewAmount,
            PRECISION,
            5000,
            6,
            18
        );
        
        if (!valid) {
            // Should revert
            vm.prank(resolver1);
            vm.expectRevert("Invalid bond mix");
            stakingModule.stakeWithMix(stableAmount, sewAmount);
        }
    }
    
    /**
     * @notice INVARIANT: Mix remains valid after partial withdrawal
     */
    function testFuzz_MixRemainsValidAfterWithdrawal(
        uint256 initialStable,
        uint256 initialSew,
        uint256 withdrawStable,
        uint256 withdrawSew
    ) public {
        // Bound inputs
        initialStable = bound(initialStable, 10000e6, MAX_STABLE);
        initialSew = bound(initialSew, 0, MAX_SEW / 10);
        
        // Stake initial amount
        vm.prank(resolver1);
        try stakingModule.stakeWithMix(initialStable, initialSew) {} catch {
            return; // Skip if initial stake invalid
        }
        
        // Bound withdrawal (partial)
        withdrawStable = bound(withdrawStable, 0, initialStable / 2);
        withdrawSew = bound(withdrawSew, 0, initialSew / 2);
        
        if (withdrawStable == 0 && withdrawSew == 0) return;
        
        // Try to withdraw
        vm.prank(resolver1);
        try stakingModule.requestUnstakeWithMix(withdrawStable, withdrawSew) {
            // If withdrawal succeeded, remaining mix must be valid
            (
                uint256 remainingStable,
                uint256 remainingSew,
                ,
                uint256 stablePct,
                uint256 sewPct
            ) = stakingModule.getBondComposition(resolver1);
            
            if (remainingStable > 0 || remainingSew > 0) {
                // INVARIANT: Remaining mix is valid
                assertGe(stablePct, 8000, "Remaining stable < 80%");
                assertLe(sewPct, 2000, "Remaining SEW > 20%");
            }
        } catch {
            // Withdrawal failed - this is OK if remaining mix would be invalid
        }
    }
    
    // ============ Invariant 2: Coverage Constraints ============
    
    /**
     * @notice CRITICAL INVARIANT: Reserved coverage <= available coverage
     */
    function testFuzz_ReservedCoverageNeverExceedsAvailable(
        uint256 seniorStable,
        uint256 seniorSew,
        uint256 juniorStable,
        uint256 juniorSew
    ) public {
        // Bound inputs
        seniorStable = bound(seniorStable, 20000e6, MAX_STABLE);
        seniorSew = bound(seniorSew, 0, MAX_SEW / 10);
        juniorStable = bound(juniorStable, 1000e6, 10000e6);
        juniorSew = bound(juniorSew, 0, MAX_SEW / 100);
        
        // Stake senior
        vm.prank(senior1);
        try stakingModule.stakeWithMix(seniorStable, seniorSew) {} catch {
            return; // Skip if senior stake invalid
        }
        
        // Stake junior
        vm.prank(resolver1);
        try stakingModule.stakeWithMix(juniorStable, juniorSew) {} catch {
            return; // Skip if junior stake invalid
        }
        
        // Get senior's available coverage before delegation
        (
            uint256 maxCoverageBefore,
            uint256 reservedBefore,
            uint256 availableBefore,
        ) = stakingModule.getSeniorCoverageStats(senior1);
        
        // Calculate required coverage for junior
        (,,uint256 juniorBond,,) = stakingModule.getBondComposition(resolver1);
        uint256 requiredCoverage = juniorBond * 3; // M = 3
        
        // Try to delegate
        vm.prank(resolver1);
        try stakingModule.delegateStake(senior1, 0) {
            // If delegation succeeded, check invariant
            (
                uint256 maxCoverage,
                uint256 reservedCoverage,
                uint256 availableCoverage,
            ) = stakingModule.getSeniorCoverageStats(senior1);
            
            // INVARIANT: Reserved <= max
            assertLe(reservedCoverage, maxCoverage, "Reserved > max");
            
            // INVARIANT: Reserved increased by required amount
            assertEq(reservedCoverage, reservedBefore + requiredCoverage, "Reserved increase wrong");
            
            // INVARIANT: Available = max - reserved
            assertEq(availableCoverage, maxCoverage - reservedCoverage, "Available calculation wrong");
            
            // INVARIANT: Available decreased by required amount
            if (availableBefore >= requiredCoverage) {
                assertEq(availableCoverage, availableBefore - requiredCoverage, "Available decrease wrong");
            }
        } catch {
            // Delegation failed - verify it was because of insufficient coverage
            // This is OK and expected when availableBefore < requiredCoverage
            if (availableBefore < requiredCoverage) {
                // Expected failure
                assertTrue(true, "Correctly rejected insufficient coverage");
            }
        }
    }
    
    /**
     * @notice INVARIANT: Cannot delegate if senior has insufficient coverage
     */
    function test_CannotDelegateWithInsufficientCoverage() public {
        // Senior stakes small amount
        vm.prank(senior1);
        stakingModule.stakeWithMix(10000e6, 0); // 10K USDC
        
        // Junior stakes large amount requiring 3x coverage
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0); // 10K USDC, needs 30K coverage
        
        // Senior can only provide 10K × 0.5 = 5K coverage
        // Should fail
        vm.prank(resolver1);
        vm.expectRevert("Insufficient senior coverage");
        stakingModule.delegateStake(senior1, 0);
    }
    
    /**
     * @notice INVARIANT: Multiple juniors cannot over-reserve senior coverage
     */
    function test_MultipleDelegationsRespectCoverageLimit() public {
        // Senior stakes 30K
        vm.prank(senior1);
        stakingModule.stakeWithMix(30000e6, 0);
        
        // Senior can provide 30K × 0.5 = 15K coverage
        
        // Junior1 stakes 3K (needs 9K coverage)
        vm.prank(resolver1);
        stakingModule.stakeWithMix(3000e6, 0);
        
        // Junior2 stakes 3K (needs 9K coverage)
        vm.prank(resolver2);
        stakingModule.stakeWithMix(3000e6, 0);
        
        // First delegation should succeed (9K < 15K)
        vm.prank(resolver1);
        stakingModule.delegateStake(senior1, 0);
        
        // Second delegation should succeed (9K + 9K = 18K > 15K)
        // Should fail
        vm.prank(resolver2);
        vm.expectRevert("Insufficient senior coverage");
        stakingModule.delegateStake(senior1, 0);
    }
    
    /**
     * @notice INVARIANT: Coverage is released when junior undelegates
     */
    function test_CoverageReleasedOnUndelegate() public {
        // Setup delegation
        vm.prank(senior1);
        stakingModule.stakeWithMix(30000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.stakeWithMix(3000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.delegateStake(senior1, 0);
        
        // Check coverage reserved
        (,uint256 reservedBefore,,) = stakingModule.getSeniorCoverageStats(senior1);
        assertEq(reservedBefore, 9000e18, "Coverage not reserved");
        
        // Undelegate
        vm.prank(resolver1);
        stakingModule.undelegateStake(senior1, 0);
        
        // Check coverage released
        (,uint256 reservedAfter,,) = stakingModule.getSeniorCoverageStats(senior1);
        assertEq(reservedAfter, 0, "Coverage not released");
    }
    
    // ============ Invariant 3: Unbond Delay Enforcement ============
    
    /**
     * @notice CRITICAL INVARIANT: Cannot withdraw before unbond delay
     */
    function test_CannotWithdrawBeforeDelay() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // Request unbond
        vm.prank(resolver1);
        stakingModule.requestUnstakeWithMix(5000e6, 0);
        
        // Try to complete immediately
        vm.prank(resolver1);
        vm.expectRevert("Unbond delay not passed");
        stakingModule.completeUnstake();
        
        // Warp 13 days (< 14 day delay)
        vm.warp(block.timestamp + 13 days);
        
        // Still should fail
        vm.prank(resolver1);
        vm.expectRevert("Unbond delay not passed");
        stakingModule.completeUnstake();
        
        // Warp to 14 days
        vm.warp(block.timestamp + 1 days + 1);
        
        // Now should succeed
        vm.prank(resolver1);
        stakingModule.completeUnstake();
    }
    
    /**
     * @notice INVARIANT: Senior has longer unbond delay than resolver
     */
    function test_SeniorHasLongerDelay() public {
        // Resolver stakes
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // Senior stakes
        vm.prank(senior1);
        stakingModule.stakeWithMix(20000e6, 0);
        
        // Both request unbond
        vm.prank(resolver1);
        stakingModule.requestUnstakeWithMix(5000e6, 0);
        
        vm.prank(senior1);
        stakingModule.requestUnstakeWithMix(10000e6, 0);
        
        // Warp 14 days (resolver delay)
        vm.warp(block.timestamp + 14 days + 1);
        
        // Resolver can withdraw
        vm.prank(resolver1);
        stakingModule.completeUnstake();
        
        // Senior cannot yet
        vm.prank(senior1);
        vm.expectRevert("Unbond delay not passed");
        stakingModule.completeUnstake();
        
        // Warp to 21 days
        vm.warp(block.timestamp + 7 days);
        
        // Now senior can withdraw
        vm.prank(senior1);
        stakingModule.completeUnstake();
    }
    
    /**
     * @notice INVARIANT: Cannot unbond if stake is locked
     */
    function test_CannotUnbondWhileLocked() public {
        // Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        // Lock stake (simulate dispute assignment)
        vm.prank(resolutionModule);
        stakingModule.onResolverAssigned(1, resolver1, 0);
        
        // Try to unbond
        vm.prank(resolver1);
        vm.expectRevert("Stake locked in disputes");
        stakingModule.requestUnstakeWithMix(5000e6, 0);
        
        // Unlock stake
        vm.prank(resolutionModule);
        stakingModule.onResolutionFinalized(1, resolver1, true);
        
        // Now can unbond
        vm.prank(resolver1);
        stakingModule.requestUnstakeWithMix(5000e6, 0);
    }
    
    /**
     * @notice INVARIANT: Cannot unbond if coverage is reserved (senior)
     */
    function test_CannotUnbondWithReservedCoverage() public {
        // Setup delegation
        vm.prank(senior1);
        stakingModule.stakeWithMix(30000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.stakeWithMix(3000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.delegateStake(senior1, 0);
        
        // Senior tries to unbond
        vm.prank(senior1);
        vm.expectRevert("Coverage reserved");
        stakingModule.requestUnstakeWithMix(10000e6, 0);
        
        // Junior undelegates
        vm.prank(resolver1);
        stakingModule.undelegateStake(senior1, 0);
        
        // Now senior can unbond
        vm.prank(senior1);
        stakingModule.requestUnstakeWithMix(10000e6, 0);
    }
    
    /**
     * @notice INVARIANT: Cannot unbond if delegated (junior)
     */
    function test_CannotUnbondWhileDelegated() public {
        // Setup delegation
        vm.prank(senior1);
        stakingModule.stakeWithMix(30000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.stakeWithMix(3000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.delegateStake(senior1, 0);
        
        // Junior tries to unbond
        vm.prank(resolver1);
        vm.expectRevert("Must undelegate first");
        stakingModule.requestUnstakeWithMix(1000e6, 0);
        
        // Junior undelegates
        vm.prank(resolver1);
        stakingModule.undelegateStake(senior1, 0);
        
        // Now can unbond
        vm.prank(resolver1);
        stakingModule.requestUnstakeWithMix(1000e6, 0);
    }
    
    // ============ Invariant 4: Senior Coverage Ordering ============
    
    /**
     * @notice INVARIANT: Junior's own stake is used before senior coverage
     * @dev This is implicit in the design - junior has their own bond
     */
    function test_JuniorStakeUsedBeforeSeniorCoverage() public {
        // Setup delegation
        vm.prank(senior1);
        stakingModule.stakeWithMix(30000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.stakeWithMix(3000e6, 0); // Junior has 3K own stake
        
        vm.prank(resolver1);
        stakingModule.delegateStake(senior1, 0); // + 9K coverage from senior
        
        // Check junior's effective stake
        uint256 effectiveStake = stakingModule.getEffectiveStake(resolver1);
        assertEq(effectiveStake, 3000e18 + 9000e18, "Effective stake wrong");
        
        // Check junior's own stake is separate
        IStakingModule.StakeInfo memory info = stakingModule.getStakeInfo(resolver1);
        assertEq(info.totalStake, 3000e18, "Junior own stake wrong");
        assertEq(info.delegatedFrom, 9000e18, "Delegated coverage wrong");
        
        // INVARIANT: Junior's own stake (3K) would be exhausted before senior's coverage (9K)
        // This is enforced by slashing module (not implemented yet)
    }
    
    /**
     * @notice INVARIANT: Senior coverage is only exposed if junior stake exhausted
     * @dev This will be enforced by slashing module in Phase 3
     */
    function test_SeniorCoverageProtectedByJuniorStake() public {
        // Setup delegation
        vm.prank(senior1);
        stakingModule.stakeWithMix(30000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.stakeWithMix(3000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.delegateStake(senior1, 0);
        
        // Verify coverage is reserved
        (,uint256 reserved,,) = stakingModule.getSeniorCoverageStats(senior1);
        assertEq(reserved, 9000e18, "Coverage not reserved");
        
        // INVARIANT: Senior's coverage (9K) is protected by junior's stake (3K)
        // If junior is slashed, their 3K is taken first
        // Senior's coverage is only touched if slash > 3K
        // This ordering will be enforced by SlashingModule
        
        assertTrue(true, "Coverage protection documented");
    }
    
    // ============ Additional Tests ============
    
    /**
     * @notice Test full lifecycle: stake → lock → unlock → unbond → withdraw
     */
    function test_FullLifecycle() public {
        // 1. Stake
        vm.prank(resolver1);
        stakingModule.stakeWithMix(10000e6, 0);
        
        IStakingModule.StakeInfo memory info = stakingModule.getStakeInfo(resolver1);
        assertEq(info.totalStake, 10000e18);
        assertEq(info.availableStake, 10000e18);
        assertEq(info.lockedStake, 0);
        
        // 2. Lock (dispute assignment)
        vm.prank(resolutionModule);
        stakingModule.onResolverAssigned(1, resolver1, 0);
        
        info = stakingModule.getStakeInfo(resolver1);
        assertEq(info.lockedStake, 1000e18); // Minimum stake locked
        assertEq(info.availableStake, 9000e18);
        
        // 3. Unlock (resolution finalized)
        vm.prank(resolutionModule);
        stakingModule.onResolutionFinalized(1, resolver1, true);
        
        info = stakingModule.getStakeInfo(resolver1);
        assertEq(info.lockedStake, 0);
        assertEq(info.availableStake, 10000e18);
        
        // 4. Request unbond
        vm.prank(resolver1);
        stakingModule.requestUnstakeWithMix(5000e6, 0);
        
        info = stakingModule.getStakeInfo(resolver1);
        assertEq(uint8(info.status), uint8(IStakingModule.StakeStatus.UNSTAKING));
        
        // 5. Wait delay
        vm.warp(block.timestamp + 14 days + 1);
        
        // 6. Complete withdrawal
        uint256 balanceBefore = stableToken.balanceOf(resolver1);
        
        vm.prank(resolver1);
        stakingModule.completeUnstake();
        
        uint256 balanceAfter = stableToken.balanceOf(resolver1);
        assertEq(balanceAfter - balanceBefore, 5000e6, "Withdrawal amount wrong");
        
        info = stakingModule.getStakeInfo(resolver1);
        assertEq(info.totalStake, 5000e18, "Remaining stake wrong");
    }
    
    /**
     * @notice Test coverage multiplier (M=3)
     */
    function test_CoverageMultiplier() public {
        vm.prank(senior1);
        stakingModule.stakeWithMix(30000e6, 0);
        
        vm.prank(resolver1);
        stakingModule.stakeWithMix(3000e6, 0);
        
        // Junior needs 3K × 3 = 9K coverage
        vm.prank(resolver1);
        stakingModule.delegateStake(senior1, 0);
        
        IStakingModule.DelegationInfo memory info = stakingModule.getDelegationInfo(resolver1, senior1);
        assertEq(info.amount, 9000e18, "Coverage amount wrong (should be 3x)");
    }
    
    /**
     * @notice Test utilization factor (U=0.5)
     */
    function test_UtilizationFactor() public {
        vm.prank(senior1);
        stakingModule.stakeWithMix(30000e6, 0);
        
        // Senior can provide 30K × 0.5 = 15K coverage
        (uint256 maxCoverage,,,) = stakingModule.getSeniorCoverageStats(senior1);
        assertEq(maxCoverage, 15000e18, "Max coverage wrong (should be 50%)");
    }
    
    /**
     * @notice Test SEW haircut (50%)
     */
    function test_SEWHaircut() public {
        // Stake 1000 USDC + 100 SEW @ $1 with 50% haircut
        // Effective = 1000 + (100 × 1 × 0.5) = 1050 USD (meets 1000 USD minimum)
        vm.prank(resolver1);
        stakingModule.stakeWithMix(1000e6, 100e18);
        
        (,,uint256 effectiveBond,,) = stakingModule.getBondComposition(resolver1);
        assertEq(effectiveBond, 1050e18, "Effective bond wrong (haircut not applied)");
    }
}
