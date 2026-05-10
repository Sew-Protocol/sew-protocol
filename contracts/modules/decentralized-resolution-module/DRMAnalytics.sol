// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './DecentralizedResolverStructs.sol';

/**
 * @title IDRMReadable
 * @notice Minimal read interface for DRMAnalytics to access DecentralizedResolutionModule
 */
interface IDRMReadable is DecentralizedResolverStructs {
    function getApprovedResolvers() external view returns (address[] memory);
    function getApprovedSeniorResolvers() external view returns (address[] memory);
    function resolverStats(address resolver) external view returns (ResolverStats memory);
    function resolverActive(address resolver) external view returns (bool);
}

/**
 * @title DRMAnalytics
 * @notice Read-only analytics helper for DecentralizedResolutionModule.
 * @dev Extracted from DRM to reduce bytecode size. Reads public DRM state
 *      to compute monitoring metrics that are not required on-chain in the hot path.
 */
contract DRMAnalytics {
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;

    address public immutable drm;

    constructor(address drmAddress) {
        require(drmAddress != address(0), 'DRMAnalytics: zero address');
        drm = drmAddress;
    }

    /**
     * @notice Get DR v1 phase gate metrics for upgrade readiness assessment
     * @return escalationRate Escalation rate in basis points (reversals / cases * 10000)
     * @return avgResponseTime Average resolution time in seconds (0 if no resolutions)
     * @return activeResolvers Number of currently active resolvers (standard + senior)
     * @dev DR v1 exit criteria: stable escalation rate, predictable response times, operational resolvers
     */
    function getV1PhaseGateMetrics()
        external
        view
        returns (uint256 escalationRate, uint256 avgResponseTime, uint256 activeResolvers)
    {
        IDRMReadable d = IDRMReadable(drm);

        address[] memory standard = d.getApprovedResolvers();
        address[] memory senior = d.getApprovedSeniorResolvers();

        uint256 totalCases = 0;
        uint256 totalReversals = 0;
        uint256 totalResolutionTime = 0;
        uint256 totalResolutions = 0;

        uint256 totalCount = standard.length + senior.length;
        for (uint256 i = 0; i < totalCount; i++) {
            address resolver = i < standard.length ? standard[i] : senior[i - standard.length];
            DecentralizedResolverStructs.ResolverStats memory stats = d.resolverStats(resolver);
            totalCases += stats.casesDecided;
            totalReversals += stats.reversals;
            totalResolutionTime += stats.totalResolutionTime;
            totalResolutions += stats.casesDecided;

            if (d.resolverActive(resolver)) {
                activeResolvers++;
            }
        }

        escalationRate = totalCases > 0
            ? (totalReversals * BASIS_POINTS_DENOMINATOR) / totalCases
            : 0;

        avgResponseTime = totalResolutions > 0 ? totalResolutionTime / totalResolutions : 0;
    }
}
