// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title ISlashingModule
 * @notice Interface for resolver slashing module (DR v3 placeholder)
 * @dev ⚠️ DR v3 placeholder - Not implemented in v1/v2
 *      This interface is provided for future module swaps when DR v3 is deployed.
 *      Resolver slashing is explicitly excluded from DR v1 and DR v2.
 *      Implementation is guarded behind module swap via slow lane governance.
 * @dev Slashing must be objective and contract-executed (timeouts, provable non-response, etc.)
 *      DAO governs rules/modules, not individual case outcomes.
 * @dev All resolution modules must implement ERC-165 for interface detection
 */
interface ISlashingModule is IERC165 {
    /**
     * @notice Slash tokens from a resolver's stake
     * @param resolver The resolver address to slash
     * @param amount The amount of tokens to slash
     * @param token The token address to slash
     * @param reason The reason for slashing (must be objective/verifiable)
     * @return success True if slashing was successful
     * @dev In DR v3, slashing is used to penalize resolvers for:
     *      - Timeout violations (provable non-response)
     *      - Objective contract-executed violations
     *      Slashing must NOT be subjective (not based on dispute outcomes)
     */
    function slash(
        address resolver,
        uint256 amount,
        address token,
        string calldata reason
    ) external returns (bool success);

    /**
     * @notice Get the slashable amount for a resolver
     * @param resolver The resolver address
     * @param token The token address
     * @return amount The maximum amount that can be slashed
     * @dev Returns 0 in v1/v2 (no slashing implemented)
     */
    function getSlashableAmount(
        address resolver,
        address token
    ) external view returns (uint256 amount);

    /**
     * @notice Check if a resolver can be slashed for a specific reason
     * @param resolver The resolver address
     * @param reason The reason for potential slashing
     * @return canSlash True if slashing is allowed for this reason
     * @dev In DR v3, only objective reasons are allowed (timeouts, provable violations)
     */
    function canSlash(
        address resolver,
        string calldata reason
    ) external view returns (bool canSlash);

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure returns (string memory name);

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning, e.g., "3.0.0")
     */
    function moduleVersion() external pure returns (string memory version);
}
