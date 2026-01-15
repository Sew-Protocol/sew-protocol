// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import './IArbitrator.sol';

/**
 * @title IArbitrable
 * @notice Arbitrable interface compatible with ERC-792 standard
 * @dev Contracts implementing this interface can be arbitrated by Kleros
 */
interface IArbitrable {
    event Ruling(IArbitrator indexed _arbitrator, uint256 indexed _disputeID, uint256 _ruling);

    /**
     * @notice Give a ruling for a dispute. Must be called by the arbitrator.
     * @param _disputeID ID of the dispute in the Arbitrator contract.
     * @param _ruling Ruling given by the arbitrator. 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint256 _disputeID, uint256 _ruling) external;
}
