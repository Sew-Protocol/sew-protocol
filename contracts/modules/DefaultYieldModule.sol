// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldGenerationModule.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';

/**
 * @title DefaultYieldModule
 * @notice Default yield generation module: no yield generation
 * @dev Implements IYieldGenerationModule with no-op functions (no actual yield generation)
 */
contract DefaultYieldModule is IYieldGenerationModule, ERC165 {
    using SafeERC20 for IERC20;

    /**
     * @notice Deposit for yield (no-op in default implementation)
     */
    function depositForYield(
        uint256 /* workflowId */,
        address /* token */,
        uint256 /* amount */
    ) external pure override returns (bool success, uint256 yieldTokenBalance) {
        return (true, 0);
    }

    /**
     * @notice Withdraw with yield (returns original amount)
     */
    function withdrawWithYield(
        uint256 /* workflowId */,
        address /* token */,
        uint256 originalAmount
    ) external pure override returns (bool success, uint256 actualAmount, uint256 yieldAmount) {
        return (true, originalAmount, 0);
    }

    /**
     * @notice Calculate yield (returns 0)
     */
    function calculateYield(
        uint256 /* workflowId */,
        address /* token */
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
