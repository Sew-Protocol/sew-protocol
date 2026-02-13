// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldGenerationModule.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

/**
 * @title DefaultYieldGenerationModule
 * @notice Default yield generation module: no yield generation
 * @dev Implements IYieldGenerationModule with no-op functions (no actual yield generation).
 *      This contract serves three critical purposes:
 *
 *      1. **Fallback for no-yield escrows**: Escrows can operate without yield generation.
 *         When no yield module is configured or activated, this contract allows the system
 *         to gracefully handle deposits/withdrawals with zero yield.
 *
 *      2. **Safe placeholder**: Acts as a default during development and testing before
 *         external yield sources (Aave, Compound, etc.) are configured.
 *
 *      3. **Graceful degradation**: If an active yield module (e.g., AaveYieldModule)
 *         fails or is paused, this contract can serve as a fallback to keep the escrow operational.
 *
 *      Architecture:
 *      - Generation and distribution are separate concerns (see IYieldDistributionModule)
 *      - This module only handles the "generation" side (earning yield)
 *      - DefaultYieldDistributionModule handles routing yield to recipients
 *      - Swapping yield sources (Default → Aave) only requires changing the generation module
 *      - Distribution logic remains unchanged and works with any generation module
 *
 *      Do NOT delete this contract: it is intentional and necessary for the system design.
 */
contract DefaultYieldGenerationModule is IYieldGenerationModule, ERC165 {
    using SafeERC20 for IERC20;

    /**
     * @notice Deposit for yield (no-op in default implementation)
     */
    function depositForYield(
        uint256 /* workflowId */,
        address /* token */,
        uint256 /* amount */,
        address /* escrowContract */
    ) external pure override returns (bool success, uint256 yieldTokenBalance) {
        return (true, 0);
    }

    /**
     * @notice Withdraw with yield (returns original amount)
     */
    function withdrawWithYield(
        uint256 /* workflowId */,
        address /* token */,
        uint256 originalAmount,
        address /* escrowContract */
    ) external pure override returns (bool success, uint256 actualAmount, uint256 yieldAmount) {
        return (true, originalAmount, 0);
    }

    /**
     * @notice Get empty position
     */
    function getPosition(
        uint256 /* workflowId */,
        address /* token */,
        address /* escrowContract */
    ) external pure override returns (YieldPosition memory position) {
        return YieldPosition({
            isActive: false,
            scaledShares: 0,
            principal: 0,
            currentYield: 0
        });
    }

    /**
     * @notice Calculate yield (returns 0)
     */
    function calculateYield(
        uint256 /* workflowId */,
        address /* token */,
        address /* escrowContract */
    ) external pure override returns (uint256 yieldAmount) {
        return 0;
    }

    // Note: distributeYield is not part of IYieldGenerationModule
    // Distribution is handled by IYieldDistributionModule

    /**
     * @notice Check if token is supported (default: none supported)
     */
    function isTokenSupported(address /* token */) external pure override returns (bool supported) {
        return false;
    }

    /**
     * @notice Get the approval target address for a token
     * @return approvalTarget Always returns address(0) - no approval needed for default module
     */
    function getApprovalTarget(address /* token */) external pure returns (address approvalTarget) {
        return address(0);
    }

    /**
     * @notice Get module name
     */
    function moduleName() external pure override returns (string memory) {
        return 'DefaultNoYield';
    }

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning)
     */
    function moduleVersion() external pure override returns (string memory version) {
        return '1.0.0';
    }

    /**
     * @notice Get Aave pool address (for library pattern)
     * @return poolAddress Always returns address(0) - default module doesn't support Aave
     */
    function getAavePoolAddress() external pure returns (address poolAddress) {
        return address(0);
    }

    /**
     * @notice Get aToken address for a token (for library pattern)
     * @return aTokenAddress Always returns address(0) - default module doesn't support Aave
     */
    function getATokenAddress(address /* token */) external pure returns (address aTokenAddress) {
        return address(0);
    }

    /**
     * @notice ERC-165 interface support
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IYieldGenerationModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
