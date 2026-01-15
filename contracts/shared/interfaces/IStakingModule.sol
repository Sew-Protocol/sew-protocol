// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IStakingModule
 * @notice Interface for resolver staking module (DR v3 placeholder)
 * @dev ⚠️ DR v3 placeholder - Not implemented in v1/v2
 *      This interface is provided for future module swaps when DR v3 is deployed.
 *      Resolver staking is explicitly excluded from DR v1 and DR v2.
 *      Implementation is guarded behind module swap via slow lane governance.
 * @dev All resolution modules must implement ERC-165 for interface detection
 */
interface IStakingModule is IERC165 {
    /**
     * @notice Stake tokens for a resolver
     * @param resolver The resolver address to stake for
     * @param amount The amount of tokens to stake
     * @param token The token address to stake
     * @return success True if staking was successful
     * @dev In DR v3, resolvers stake capital to participate in dispute resolution
     */
    function stake(
        address resolver,
        uint256 amount,
        address token
    ) external returns (bool success);

    /**
     * @notice Unstake tokens for a resolver
     * @param resolver The resolver address to unstake for
     * @param amount The amount of tokens to unstake
     * @return success True if unstaking was successful
     * @dev In DR v3, resolvers can unstake after a cooldown period
     */
    function unstake(
        address resolver,
        uint256 amount
    ) external returns (bool success);

    /**
     * @notice Get the total stake for a resolver
     * @param resolver The resolver address
     * @param token The token address
     * @return amount The total staked amount
     * @dev Returns 0 in v1/v2 (no staking implemented)
     */
    function getStake(
        address resolver,
        address token
    ) external view returns (uint256 amount);

    /**
     * @notice Get the minimum stake required for a resolver role
     * @param role The resolver role (0 = standard, 1 = senior, etc.)
     * @param token The token address
     * @return amount The minimum stake amount
     * @dev Returns 0 in v1/v2 (no staking implemented)
     */
    function getMinimumStake(
        uint8 role,
        address token
    ) external view returns (uint256 amount);

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
