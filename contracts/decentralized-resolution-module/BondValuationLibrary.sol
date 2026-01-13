// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

/**
 * @title BondValuationLibrary
 * @notice Library for calculating effective bond values with haircuts and mix enforcement
 * @dev Used by ResolverStakingModule to value mixed stable/SEW bonds
 * 
 * Key Concepts:
 * - Stable: USD-pegged stablecoins (USDC, DAI, etc.) - 100% value
 * - SEW: Protocol token with price risk - haircut applied
 * - Haircut: Discount factor for SEW (e.g., 0.5 = 50% haircut)
 * - Mix Enforcement: Minimum 80% stable, maximum 20% SEW (after haircut)
 * 
 * Example:
 *   stable = 800 USDC
 *   sew = 100 SEW @ $2/SEW with 50% haircut
 *   effectiveBondUSD = 800 + (100 × 2 × 0.5) = 900 USD
 *   stable% = 800/900 = 88.9% ✓ (>= 80%)
 *   sew% = 100/900 = 11.1% ✓ (<= 20%)
 */
library BondValuationLibrary {
    // Precision constants
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    
    // Mix enforcement constants (basis points)
    uint256 public constant MIN_STABLE_BPS = 8000; // 80% minimum stable
    uint256 public constant MAX_SEW_BPS = 2000;    // 20% maximum SEW (after haircut)
    
    // Haircut bounds
    uint256 public constant MIN_HAIRCUT = 0;        // 0% (no discount)
    uint256 public constant MAX_HAIRCUT = PRECISION; // 100% (full discount)
    
    /**
     * @notice Calculate effective bond value in USD
     * @param stableAmount Amount of stablecoin (in token decimals)
     * @param sewAmount Amount of SEW token (in token decimals)
     * @param sewPriceUSD Price of SEW in USD (18 decimals, e.g., 2e18 = $2)
     * @param haircutBps Haircut in basis points (e.g., 5000 = 50% haircut)
     * @param stableDecimals Decimals of stablecoin (e.g., 6 for USDC)
     * @param sewDecimals Decimals of SEW token (e.g., 18)
     * @return effectiveUSD Effective bond value in USD (18 decimals)
     * 
     * @dev Formula: effectiveUSD = stable + (sew × sewPrice × (1 - haircut))
     *      All amounts normalized to 18 decimals for calculation
     */
    function calculateEffectiveBondUSD(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPriceUSD,
        uint256 haircutBps,
        uint8 stableDecimals,
        uint8 sewDecimals
    ) internal pure returns (uint256 effectiveUSD) {
        require(haircutBps <= BASIS_POINTS, "Haircut > 100%");
        
        // Normalize stable to 18 decimals (assume 1:1 USD peg)
        uint256 stableUSD = _normalizeDecimals(stableAmount, stableDecimals, 18);
        
        // Calculate SEW value with haircut
        // sewUSD = sewAmount × sewPrice × (1 - haircut)
        uint256 sewNormalized = _normalizeDecimals(sewAmount, sewDecimals, 18);
        uint256 haircutMultiplier = BASIS_POINTS - haircutBps; // e.g., 10000 - 5000 = 5000 (50%)
        uint256 sewUSD = (sewNormalized * sewPriceUSD * haircutMultiplier) / (PRECISION * BASIS_POINTS);
        
        effectiveUSD = stableUSD + sewUSD;
    }
    
    /**
     * @notice Check if bond mix satisfies enforcement rules
     * @param stableAmount Amount of stablecoin
     * @param sewAmount Amount of SEW token
     * @param sewPriceUSD Price of SEW in USD (18 decimals)
     * @param haircutBps Haircut in basis points
     * @param stableDecimals Decimals of stablecoin
     * @param sewDecimals Decimals of SEW token
     * @return valid True if mix is valid
     * @return stablePct Stable percentage in basis points
     * @return sewPct SEW percentage in basis points
     * 
     * @dev Enforcement rules:
     *      1. stable >= 80% of effectiveBondUSD
     *      2. sew <= 20% of effectiveBondUSD (after haircut)
     */
    function checkBondMix(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 sewPriceUSD,
        uint256 haircutBps,
        uint8 stableDecimals,
        uint8 sewDecimals
    ) internal pure returns (
        bool valid,
        uint256 stablePct,
        uint256 sewPct
    ) {
        uint256 effectiveUSD = calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            sewPriceUSD,
            haircutBps,
            stableDecimals,
            sewDecimals
        );
        
        if (effectiveUSD == 0) {
            return (false, 0, 0);
        }
        
        // Calculate percentages in basis points
        uint256 stableUSD = _normalizeDecimals(stableAmount, stableDecimals, 18);
        stablePct = (stableUSD * BASIS_POINTS) / effectiveUSD;
        sewPct = BASIS_POINTS - stablePct; // Remainder is SEW
        
        // Check enforcement rules
        valid = (stablePct >= MIN_STABLE_BPS) && (sewPct <= MAX_SEW_BPS);
    }
    
    /**
     * @notice Calculate maximum SEW amount allowed for a given stable amount
     * @param stableAmount Amount of stablecoin
     * @param sewPriceUSD Price of SEW in USD (18 decimals)
     * @param haircutBps Haircut in basis points
     * @param stableDecimals Decimals of stablecoin
     * @param sewDecimals Decimals of SEW token
     * @return maxSewAmount Maximum SEW amount that satisfies mix rules
     * 
     * @dev Formula: maxSEW = (effectiveBondUSD × 0.2) / (sewPrice × (1 - haircut))
     *      Where effectiveBondUSD = stable / 0.8
     */
    function calculateMaxSEW(
        uint256 stableAmount,
        uint256 sewPriceUSD,
        uint256 haircutBps,
        uint8 stableDecimals,
        uint8 sewDecimals
    ) internal pure returns (uint256 maxSewAmount) {
        require(haircutBps <= BASIS_POINTS, "Haircut > 100%");
        require(sewPriceUSD > 0, "SEW price = 0");
        
        // If stable is 80%, total bond = stable / 0.8
        // SEW can be 20% of total = (stable / 0.8) × 0.2 = stable / 4
        uint256 stableUSD = _normalizeDecimals(stableAmount, stableDecimals, 18);
        uint256 maxSewUSD = (stableUSD * MAX_SEW_BPS) / MIN_STABLE_BPS;
        
        // Convert SEW USD value to SEW tokens (accounting for haircut)
        // sewUSD = sewAmount × sewPrice × (1 - haircut)
        // sewAmount = sewUSD / (sewPrice × (1 - haircut))
        uint256 haircutMultiplier = BASIS_POINTS - haircutBps;
        if (haircutMultiplier == 0) {
            return 0; // 100% haircut means no SEW allowed
        }
        
        uint256 sewAmountNormalized = (maxSewUSD * PRECISION * BASIS_POINTS) / (sewPriceUSD * haircutMultiplier);
        maxSewAmount = _normalizeDecimals(sewAmountNormalized, 18, sewDecimals);
    }
    
    /**
     * @notice Calculate minimum stable amount required for a given SEW amount
     * @param sewAmount Amount of SEW token
     * @param sewPriceUSD Price of SEW in USD (18 decimals)
     * @param haircutBps Haircut in basis points
     * @param stableDecimals Decimals of stablecoin
     * @param sewDecimals Decimals of SEW token
     * @return minStableAmount Minimum stable amount that satisfies mix rules
     * 
     * @dev Formula: minStable = (sewUSD × 0.8) / 0.2 = sewUSD × 4
     *      Where sewUSD = sewAmount × sewPrice × (1 - haircut)
     */
    function calculateMinStable(
        uint256 sewAmount,
        uint256 sewPriceUSD,
        uint256 haircutBps,
        uint8 stableDecimals,
        uint8 sewDecimals
    ) internal pure returns (uint256 minStableAmount) {
        require(haircutBps <= BASIS_POINTS, "Haircut > 100%");
        
        // Calculate SEW USD value (with haircut)
        uint256 sewNormalized = _normalizeDecimals(sewAmount, sewDecimals, 18);
        uint256 haircutMultiplier = BASIS_POINTS - haircutBps;
        uint256 sewUSD = (sewNormalized * sewPriceUSD * haircutMultiplier) / (PRECISION * BASIS_POINTS);
        
        // If SEW is 20%, stable must be 80% = SEW × 4
        uint256 minStableUSD = (sewUSD * MIN_STABLE_BPS) / MAX_SEW_BPS;
        minStableAmount = _normalizeDecimals(minStableUSD, 18, stableDecimals);
    }
    
    /**
     * @notice Check if senior resolver has sufficient coverage for reserved amount
     * @param effectiveBondUSD Senior's effective bond value (18 decimals)
     * @param utilizationBps Utilization factor in basis points (e.g., 5000 = 50%)
     * @param reservedCoverageUSD Total coverage reserved by junior resolvers (18 decimals)
     * @return sufficient True if coverage is sufficient
     * @return availableCoverage Available coverage in USD (18 decimals)
     * @return shortfall Shortfall in USD if insufficient (18 decimals)
     * 
     * @dev Formula: availableCoverage = effectiveBondUSD × utilizationBps / 10000
     *      Coverage is sufficient if: availableCoverage >= reservedCoverageUSD
     */
    function checkCoverage(
        uint256 effectiveBondUSD,
        uint256 utilizationBps,
        uint256 reservedCoverageUSD
    ) internal pure returns (
        bool sufficient,
        uint256 availableCoverage,
        uint256 shortfall
    ) {
        require(utilizationBps <= BASIS_POINTS, "Utilization > 100%");
        
        availableCoverage = (effectiveBondUSD * utilizationBps) / BASIS_POINTS;
        
        if (availableCoverage >= reservedCoverageUSD) {
            sufficient = true;
            shortfall = 0;
        } else {
            sufficient = false;
            shortfall = reservedCoverageUSD - availableCoverage;
        }
    }
    
    /**
     * @notice Calculate maximum coverage a senior can provide
     * @param effectiveBondUSD Senior's effective bond value (18 decimals)
     * @param utilizationBps Utilization factor in basis points
     * @return maxCoverage Maximum coverage in USD (18 decimals)
     */
    function calculateMaxCoverage(
        uint256 effectiveBondUSD,
        uint256 utilizationBps
    ) internal pure returns (uint256 maxCoverage) {
        require(utilizationBps <= BASIS_POINTS, "Utilization > 100%");
        maxCoverage = (effectiveBondUSD * utilizationBps) / BASIS_POINTS;
    }
    
    /**
     * @notice Simulate SEW price crash and check coverage impact
     * @param stableAmount Amount of stablecoin
     * @param sewAmount Amount of SEW token
     * @param originalSewPrice Original SEW price (18 decimals)
     * @param newSewPrice New SEW price after crash (18 decimals)
     * @param haircutBps Haircut in basis points
     * @param utilizationBps Utilization factor in basis points
     * @param reservedCoverageUSD Reserved coverage (18 decimals)
     * @param stableDecimals Decimals of stablecoin
     * @param sewDecimals Decimals of SEW token
     * @return originalCoverage Coverage before crash
     * @return newCoverage Coverage after crash
     * @return coverageStillSufficient True if coverage still sufficient after crash
     */
    function simulatePriceCrash(
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 originalSewPrice,
        uint256 newSewPrice,
        uint256 haircutBps,
        uint256 utilizationBps,
        uint256 reservedCoverageUSD,
        uint8 stableDecimals,
        uint8 sewDecimals
    ) internal pure returns (
        uint256 originalCoverage,
        uint256 newCoverage,
        bool coverageStillSufficient
    ) {
        // Calculate original coverage
        uint256 originalBond = calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            originalSewPrice,
            haircutBps,
            stableDecimals,
            sewDecimals
        );
        originalCoverage = calculateMaxCoverage(originalBond, utilizationBps);
        
        // Calculate coverage after crash
        uint256 newBond = calculateEffectiveBondUSD(
            stableAmount,
            sewAmount,
            newSewPrice,
            haircutBps,
            stableDecimals,
            sewDecimals
        );
        newCoverage = calculateMaxCoverage(newBond, utilizationBps);
        
        // Check if still sufficient
        coverageStillSufficient = (newCoverage >= reservedCoverageUSD);
    }
    
    // ============ Internal Helper Functions ============
    
    /**
     * @notice Normalize token amount from one decimal precision to another
     * @param amount Amount in source decimals
     * @param fromDecimals Source decimals
     * @param toDecimals Target decimals
     * @return normalized Amount in target decimals
     */
    function _normalizeDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) private pure returns (uint256 normalized) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals < toDecimals) {
            // Scale up
            uint8 diff = toDecimals - fromDecimals;
            normalized = amount * (10 ** diff);
        } else {
            // Scale down
            uint8 diff = fromDecimals - toDecimals;
            normalized = amount / (10 ** diff);
        }
    }
    
    /**
     * @notice Validate haircut is within bounds
     * @param haircutBps Haircut in basis points
     * @return valid True if valid
     */
    function isValidHaircut(uint256 haircutBps) internal pure returns (bool valid) {
        return haircutBps <= BASIS_POINTS;
    }
    
    /**
     * @notice Validate utilization is within bounds
     * @param utilizationBps Utilization in basis points
     * @return valid True if valid
     */
    function isValidUtilization(uint256 utilizationBps) internal pure returns (bool valid) {
        return utilizationBps <= BASIS_POINTS;
    }
}
