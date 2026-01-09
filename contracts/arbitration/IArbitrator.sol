// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "./IArbitrable.sol";

/**
 * @title IArbitrator
 * @notice Arbitrator interface compatible with ERC-792 standard
 * @dev This interface defines the arbitrator contract that can arbitrate disputes
 */
interface IArbitrator {
    enum DisputeStatus {
        Waiting,
        Appealable,
        Solved
    }

    event DisputeCreation(uint256 indexed _disputeID, IArbitrable indexed _arbitrable);
    event AppealPossible(uint256 indexed _disputeID, IArbitrable indexed _arbitrable);
    event AppealDecision(uint256 indexed _disputeID, IArbitrable indexed _arbitrable);

    /**
     * @notice Create a dispute. Must be called by the arbitrable contract.
     * @param _choices Amount of choices the arbitrator can make in this dispute.
     * @param _extraData Additional data for the arbitrator.
     * @return disputeID ID of the dispute created.
     */
    function createDispute(uint256 _choices, bytes calldata _extraData) 
        external 
        payable 
        returns (uint256 disputeID);

    /**
     * @notice Compute the cost of arbitration.
     * @param _extraData Additional data for the arbitrator.
     * @return cost Required cost of arbitration.
     */
    function arbitrationCost(bytes calldata _extraData) 
        external 
        view 
        returns (uint256 cost);

    /**
     * @notice Appeal a ruling. Must be called by the arbitrable contract.
     * @param _disputeID ID of the dispute to be appealed.
     * @param _extraData Additional data for the arbitrator.
     */
    function appeal(uint256 _disputeID, bytes calldata _extraData) 
        external 
        payable;

    /**
     * @notice Compute the cost of appeal.
     * @param _disputeID ID of the dispute to be appealed.
     * @param _extraData Additional data for the arbitrator.
     * @return cost Required cost of appeal.
     */
    function appealCost(uint256 _disputeID, bytes calldata _extraData) 
        external 
        view 
        returns (uint256 cost);

    /**
     * @notice Get the status of a dispute.
     * @param _disputeID ID of the dispute.
     * @return status The status of the dispute.
     */
    function disputeStatus(uint256 _disputeID) 
        external 
        view 
        returns (DisputeStatus status);

    /**
     * @notice Get the current ruling of a dispute.
     * @param _disputeID ID of the dispute.
     * @return ruling The ruling which has been given or the one which will be given if there is no appeal.
     */
    function currentRuling(uint256 _disputeID) 
        external 
        view 
        returns (uint256 ruling);
}
