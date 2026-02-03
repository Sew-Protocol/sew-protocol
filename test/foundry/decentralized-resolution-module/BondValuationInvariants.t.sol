// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/BondValuationLibrary.sol';

/**
 * @title BondValuationInvariantsTest
 * @notice Comprehensive invariant and fuzz tests for BondValuationLibrary
 * @dev Tests critical properties:
 *      1. No resolver/senior can exceed coverage even if SEW price → 0
 *      2. Mix enforcement always satisfied
 *      3. Effective bond value monotonic with inputs
 *      4. Coverage bounds respected
 */
contract BondValuationInvariantsTest is Test {
    using BondValuationLibrary for *;

    // Test constants
    uint8 constant STABLE_DECIMALS = 6; // USDC
    uint8 constant SEW_DECIMALS = 18; // SEW token
    uint256 constant PRECISION = 1e18;
    uint256 constant BASIS_POINTS = 10000;

    // Reasonable bounds for fuzzing
    uint256 constant MAX_STABLE = 1_000_000e6; // 1M USDC
    uint256 constant MAX_SEW = 1_000_000e18; // 1M SEW
    uint256 constant MAX_PRICE = 1000e18; // $1000/SEW
    uint256 constant MAX_HAIRCUT = 9000; // 90% haircut
    uint256 constant MAX_UTILIZATION = 10000; // 100% utilization

    // ============ Invariant 1: Coverage Never Exceeds Bond (Even at SEW=0) ============

    /**
     * @notice CRITICAL INVARIANT: Coverage can never exceed effective bond value
     * @dev Even if SEW price crashes to $0, stable component ensures coverage bounds
     */
    function testFuzz_CoverageNeverExceedsBond(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps,
        uint256 utilizationBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 0, MAX_STABLE);
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        sewPrice = bound(sewPrice, 0, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);
        utilizationBps = bound(utilizationBps, 0, MAX_UTILIZATION);

        // Calculate effective bond
        uint256 effectiveBond = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // Calculate max coverage
        uint256 maxCoverage = BondValuationLibrary.calculateMaxCoverage(
            effectiveBond,
            utilizationBps
        );

        // INVARIANT: Coverage <= Bond
        assertLe(maxCoverage, effectiveBond, 'Coverage exceeds bond');

        // CRITICAL: Test with SEW price = 0 (worst case)
        uint256 effectiveBondAtZero = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            0, // SEW price crashes to $0
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        uint256 maxCoverageAtZero = BondValuationLibrary.calculateMaxCoverage(
            effectiveBondAtZero,
            utilizationBps
        );

        // INVARIANT: Coverage at SEW=0 still <= Bond at SEW=0
        assertLe(maxCoverageAtZero, effectiveBondAtZero, 'Coverage exceeds bond at SEW=0');

        // INVARIANT: Bond at SEW=0 is just the stable component
        uint256 stableUSD = (uint256(stableAmount) * PRECISION) / (10 ** STABLE_DECIMALS);
        assertEq(effectiveBondAtZero, stableUSD, 'Bond at SEW=0 should equal stable');
    }

    /**
     * @notice CRITICAL INVARIANT: 80% stable ensures minimum coverage even if SEW→0
     * @dev With 80% stable minimum, coverage floor = stable × utilization
     */
    function testFuzz_StableComponentEnforcesCoverageFloor(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps,
        uint256 utilizationBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 1e6, MAX_STABLE); // At least 1 USDC
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        sewPrice = bound(sewPrice, 0, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);
        utilizationBps = bound(utilizationBps, 0, MAX_UTILIZATION);

        // Check if mix is valid
        (bool valid, , ) = BondValuationLibrary.checkBondMix(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        if (!valid) return; // Skip invalid mixes

        // Calculate coverage at current price
        uint256 effectiveBond = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );
        uint256 coverage = BondValuationLibrary.calculateMaxCoverage(effectiveBond, utilizationBps);

        // Calculate coverage floor (SEW = 0)
        uint256 stableUSD = (uint256(stableAmount) * PRECISION) / (10 ** STABLE_DECIMALS);
        uint256 coverageFloor = (stableUSD * utilizationBps) / BASIS_POINTS;

        // INVARIANT: Coverage floor is at least 80% of current coverage
        // (because stable is at least 80% of bond)
        uint256 minExpectedFloor = (coverage * 8000) / BASIS_POINTS;
        assertGe(coverageFloor, minExpectedFloor, 'Coverage floor too low');
    }

    // ============ Invariant 2: Mix Enforcement ============

    /**
     * @notice INVARIANT: Valid bonds always have >= 80% stable
     */
    function testFuzz_ValidBondsHaveMinimumStable(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 0, MAX_STABLE);
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        sewPrice = bound(sewPrice, 0, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);

        (bool valid, uint256 stablePct, ) = BondValuationLibrary.checkBondMix(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        if (valid) {
            // INVARIANT: Valid bonds have >= 80% stable
            assertGe(stablePct, 8000, 'Valid bond has < 80% stable');
        }
    }

    /**
     * @notice INVARIANT: Valid bonds always have <= 20% SEW (after haircut)
     */
    function testFuzz_ValidBondsHaveMaximumSEW(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 0, MAX_STABLE);
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        sewPrice = bound(sewPrice, 0, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);

        (bool valid, , uint256 sewPct) = BondValuationLibrary.checkBondMix(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        if (valid) {
            // INVARIANT: Valid bonds have <= 20% SEW
            assertLe(sewPct, 2000, 'Valid bond has > 20% SEW');
        }
    }

    /**
     * @notice INVARIANT: Percentages always sum to 100%
     */
    function testFuzz_PercentagesSumTo100(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 1, MAX_STABLE);
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        sewPrice = bound(sewPrice, 0, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);

        (, uint256 stablePct, uint256 sewPct) = BondValuationLibrary.checkBondMix(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // INVARIANT: Percentages sum to 10000 (100%)
        assertEq(stablePct + sewPct, BASIS_POINTS, "Percentages don't sum to 100%");
    }

    // ============ Invariant 3: Monotonicity ============

    /**
     * @notice INVARIANT: Effective bond increases with stable amount
     */
    function testFuzz_BondMonotonicInStable(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 1e6, MAX_STABLE - 1e6);
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        sewPrice = bound(sewPrice, 0, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);

        uint256 bond1 = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        uint256 bond2 = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount + 1e6, // Add 1 USDC
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // INVARIANT: More stable → higher bond
        assertGe(bond2, bond1, 'Bond not monotonic in stable');
    }

    /**
     * @notice INVARIANT: Effective bond increases with SEW amount (if price > 0)
     */
    function testFuzz_BondMonotonicInSEW(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 0, MAX_STABLE);
        sewAmount = bound(sewAmount, 1e18, MAX_SEW - 1e18);
        sewPrice = bound(sewPrice, 1e18, MAX_PRICE); // Price > 0
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT - 1); // Haircut < 100%

        uint256 bond1 = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        uint256 bond2 = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount + 1e18, // Add 1 SEW
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // INVARIANT: More SEW → higher bond (if price > 0 and haircut < 100%)
        assertGe(bond2, bond1, 'Bond not monotonic in SEW');
    }

    /**
     * @notice INVARIANT: Effective bond decreases with haircut
     */
    function testFuzz_BondDecreasesWithHaircut(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 0, MAX_STABLE);
        sewAmount = bound(sewAmount, 1e18, MAX_SEW);
        sewPrice = bound(sewPrice, 1e18, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT - 100); // Leave room for +100

        uint256 bond1 = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        uint256 bond2 = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps + 100, // Increase haircut by 1%
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // INVARIANT: Higher haircut → lower bond
        assertLe(bond2, bond1, 'Bond not decreasing with haircut');
    }

    // ============ Invariant 4: Coverage Bounds ============

    /**
     * @notice INVARIANT: Coverage is always <= bond × utilization
     */
    function testFuzz_CoverageRespectsBounds(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps,
        uint256 utilizationBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 0, MAX_STABLE);
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        sewPrice = bound(sewPrice, 0, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);
        utilizationBps = bound(utilizationBps, 0, MAX_UTILIZATION);

        uint256 effectiveBond = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        uint256 maxCoverage = BondValuationLibrary.calculateMaxCoverage(
            effectiveBond,
            utilizationBps
        );

        uint256 expectedMax = (effectiveBond * utilizationBps) / BASIS_POINTS;

        // INVARIANT: Coverage exactly equals bond × utilization
        assertEq(maxCoverage, expectedMax, "Coverage doesn't match formula");
    }

    /**
     * @notice INVARIANT: Coverage check is consistent with max coverage
     */
    function testFuzz_CoverageCheckConsistent(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps,
        uint256 utilizationBps,
        uint256 reservedCoverage
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 0, MAX_STABLE);
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        sewPrice = bound(sewPrice, 0, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);
        utilizationBps = bound(utilizationBps, 0, MAX_UTILIZATION);

        uint256 effectiveBond = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        uint256 maxCoverage = BondValuationLibrary.calculateMaxCoverage(
            effectiveBond,
            utilizationBps
        );

        reservedCoverage = bound(reservedCoverage, 0, maxCoverage * 2);

        (bool sufficient, uint256 available, uint256 shortfall) = BondValuationLibrary
            .checkCoverage(effectiveBond, utilizationBps, reservedCoverage);

        // INVARIANT: Available coverage equals max coverage
        assertEq(available, maxCoverage, 'Available != max coverage');

        // INVARIANT: Sufficient iff reserved <= available
        if (sufficient) {
            assertLe(reservedCoverage, available, 'Sufficient but reserved > available');
            assertEq(shortfall, 0, 'Sufficient but shortfall != 0');
        } else {
            assertGt(reservedCoverage, available, 'Insufficient but reserved <= available');
            assertEq(shortfall, reservedCoverage - available, 'Shortfall calculation wrong');
        }
    }

    // ============ Invariant 5: Price Crash Scenarios ============

    /**
     * @notice CRITICAL INVARIANT: Coverage remains sufficient after any price crash
     *         IF initial bond had sufficient stable component
     */
    function testFuzz_CoverageSurvivesPriceCrash(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 originalPrice,
        uint256 haircutBps,
        uint256 utilizationBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 1e6, MAX_STABLE);
        sewAmount = bound(sewAmount, 0, MAX_SEW);
        originalPrice = bound(originalPrice, 1e18, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);
        utilizationBps = bound(utilizationBps, 0, MAX_UTILIZATION);

        // Check if mix is valid at original price
        (bool valid, , ) = BondValuationLibrary.checkBondMix(
            stableAmount,
            sewAmount,
            originalPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        if (!valid) return; // Skip invalid mixes

        // Calculate original coverage
        uint256 originalBond = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            originalPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );
        uint256 originalCoverage = BondValuationLibrary.calculateMaxCoverage(
            originalBond,
            utilizationBps
        );

        // Reserve 100% of coverage (worst case)
        uint256 reservedCoverage = originalCoverage;

        // Simulate price crash to $0
        (
            uint256 coverageBeforeCrash,
            uint256 coverageAfterCrash,
            bool stillSufficient
        ) = BondValuationLibrary.simulatePriceCrash(
                stableAmount,
                sewAmount,
                originalPrice,
                0, // Price crashes to $0
                haircutBps,
                utilizationBps,
                reservedCoverage,
                STABLE_DECIMALS,
                SEW_DECIMALS
            );

        // INVARIANT: Coverage before crash equals original coverage
        assertEq(coverageBeforeCrash, originalCoverage, 'Coverage mismatch');

        // INVARIANT: Coverage after crash is at least 80% of original
        // (because stable is at least 80% of bond)
        uint256 minExpectedCoverage = (originalCoverage * 8000) / BASIS_POINTS;
        assertGe(coverageAfterCrash, minExpectedCoverage, 'Coverage dropped too much');

        // INVARIANT: If we reserved exactly 80% of original coverage,
        // it should still be sufficient after crash
        uint256 conservativeReserved = (originalCoverage * 8000) / BASIS_POINTS;
        (, , bool conservativeSufficient) = BondValuationLibrary.simulatePriceCrash(
            stableAmount,
            sewAmount,
            originalPrice,
            0,
            haircutBps,
            utilizationBps,
            conservativeReserved,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        assertTrue(conservativeSufficient, 'Conservative reservation insufficient after crash');
    }

    /**
     * @notice INVARIANT: 100% stable bonds are immune to price crashes
     */
    function testFuzz_PureStableBondsImmuneToPrice(
        uint256 stableAmount,
        uint256 sewPrice,
        uint256 haircutBps,
        uint256 utilizationBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 1e6, MAX_STABLE);
        sewPrice = bound(sewPrice, 0, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);
        utilizationBps = bound(utilizationBps, 0, MAX_UTILIZATION);

        // Calculate bond with 0 SEW
        uint256 bond1 = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            0, // No SEW
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // Calculate bond with different price
        uint256 bond2 = BondValuationLibrary.calculateEffectiveBondUSD(
            stableAmount,
            0, // No SEW
            sewPrice / 2, // Price halves
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // INVARIANT: Pure stable bonds unaffected by price
        assertEq(bond1, bond2, 'Pure stable bond affected by price');

        // Calculate coverage
        uint256 coverage1 = BondValuationLibrary.calculateMaxCoverage(bond1, utilizationBps);
        uint256 coverage2 = BondValuationLibrary.calculateMaxCoverage(bond2, utilizationBps);

        // INVARIANT: Coverage also unaffected
        assertEq(coverage1, coverage2, 'Pure stable coverage affected by price');
    }

    // ============ Fuzz Tests: Max/Min Calculations ============

    function testFuzz_MaxSEWCalculation(
        uint256 stableAmount,
        uint256 sewPrice,
        uint256 haircutBps
    ) public {
        // Bound inputs
        stableAmount = bound(stableAmount, 1e6, MAX_STABLE);
        sewPrice = bound(sewPrice, 1e15, MAX_PRICE); // Min $0.001
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT - 1); // < 100%

        uint256 maxSew = BondValuationLibrary.calculateMaxSEW(
            stableAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // Check if this max SEW results in valid mix
        (bool valid, uint256 stablePct, uint256 sewPct) = BondValuationLibrary.checkBondMix(
            stableAmount,
            maxSew,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // Should be valid (or very close to boundary)
        assertTrue(valid || sewPct <= 2001, 'Max SEW results in invalid mix');

        // If valid, SEW should be close to 20%
        if (valid) {
            assertLe(sewPct, 2000, 'Max SEW exceeds 20%');
            assertGe(sewPct, 1900, 'Max SEW too conservative'); // Allow 1% tolerance
        }
    }

    function testFuzz_MinStableCalculation(
        uint256 sewAmount,
        uint256 sewPrice,
        uint256 haircutBps
    ) public {
        // Bound inputs
        sewAmount = bound(sewAmount, 1e18, MAX_SEW);
        sewPrice = bound(sewPrice, 1e15, MAX_PRICE);
        haircutBps = bound(haircutBps, 0, MAX_HAIRCUT);

        uint256 minStable = BondValuationLibrary.calculateMinStable(
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // Check if this min stable results in valid mix
        (bool valid, uint256 stablePct, ) = BondValuationLibrary.checkBondMix(
            minStable,
            sewAmount,
            sewPrice,
            haircutBps,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // Should be valid (or very close to boundary)
        assertTrue(valid || stablePct >= 7999, 'Min stable results in invalid mix');

        // If valid, stable should be close to 80%
        if (valid) {
            assertGe(stablePct, 8000, 'Min stable below 80%');
            assertLe(stablePct, 8100, 'Min stable too conservative'); // Allow 1% tolerance
        }
    }

    // ============ Edge Cases ============

    function test_ZeroSEWPrice() public {
        uint256 stable = 1000e6; // 1000 USDC
        uint256 sew = 100e18; // 100 SEW
        uint256 haircut = 5000; // 50%

        uint256 bond = BondValuationLibrary.calculateEffectiveBondUSD(
            stable,
            sew,
            0, // Price = 0
            haircut,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // Should equal stable component only
        uint256 expectedBond = 1000e18;
        assertEq(bond, expectedBond, 'Bond wrong at SEW=0');
    }

    function test_ZeroHaircut() public {
        uint256 stable = 800e6; // 800 USDC
        uint256 sew = 100e18; // 100 SEW
        uint256 price = 2e18; // $2/SEW

        uint256 bond = BondValuationLibrary.calculateEffectiveBondUSD(
            stable,
            sew,
            price,
            0, // No haircut
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // Should equal stable + full SEW value
        uint256 expectedBond = 800e18 + 200e18; // 1000 USD
        assertEq(bond, expectedBond, 'Bond wrong at 0% haircut');
    }

    function test_FullHaircut() public {
        uint256 stable = 1000e6; // 1000 USDC
        uint256 sew = 100e18; // 100 SEW
        uint256 price = 2e18; // $2/SEW

        uint256 bond = BondValuationLibrary.calculateEffectiveBondUSD(
            stable,
            sew,
            price,
            10000, // 100% haircut
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        // Should equal stable component only
        uint256 expectedBond = 1000e18;
        assertEq(bond, expectedBond, 'Bond wrong at 100% haircut');
    }

    function test_PureStableBond() public {
        uint256 stable = 1000e6; // 1000 USDC

        uint256 bond = BondValuationLibrary.calculateEffectiveBondUSD(
            stable,
            0, // No SEW
            2e18,
            5000,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        (bool valid, uint256 stablePct, uint256 sewPct) = BondValuationLibrary.checkBondMix(
            stable,
            0,
            2e18,
            5000,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );

        assertEq(bond, 1000e18, 'Pure stable bond wrong');
        assertTrue(valid, 'Pure stable bond invalid');
        assertEq(stablePct, 10000, 'Pure stable not 100%');
        assertEq(sewPct, 0, 'Pure stable has SEW%');
    }
}
