// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import '../IArbitrator.sol';
import '../IArbitrable.sol';

/**
 * @title MockKlerosArbitrator
 * @notice Mock implementation of Kleros arbitrator for testing
 */
contract MockKlerosArbitrator is IArbitrator {
    struct Dispute {
        IArbitrable arbitrable;
        uint256 choices;
        uint256 ruling;
        DisputeStatus status;
    }

    Dispute[] public disputes;
    uint256 public arbitrationPrice;

    // Custom dispute ID override (for sentinel overflow testing)
    uint256 public customDisputeId;
    bool public useCustomId;

    constructor(uint256 _arbitrationPrice) {
        arbitrationPrice = _arbitrationPrice;
    }

    function setNextDisputeId(uint256 id) external {
        customDisputeId = id;
        useCustomId = true;
    }

    function setArbitrationPrice(uint256 _arbitrationPrice) external {
        arbitrationPrice = _arbitrationPrice;
    }

    function createDispute(
        uint256 _choices,
        bytes calldata
    ) external payable override returns (uint256 disputeID) {
        require(msg.value >= arbitrationPrice, 'Insufficient payment');

        disputes.push(
            Dispute({
                arbitrable: IArbitrable(msg.sender),
                choices: _choices,
                ruling: 0,
                status: DisputeStatus.Waiting
            })
        );

        if (useCustomId) {
            disputeID = customDisputeId;
            useCustomId = false;
        } else {
            disputeID = disputes.length - 1;
        }

        emit DisputeCreation(disputeID, IArbitrable(msg.sender));

        return disputeID;
    }

    function arbitrationCost(bytes calldata) external view override returns (uint256 cost) {
        return arbitrationPrice;
    }

    function appeal(uint256, bytes calldata) external payable override {
        revert('Appeal not implemented in mock');
    }

    function appealCost(uint256, bytes calldata) external view override returns (uint256) {
        return arbitrationPrice;
    }

    function disputeStatus(uint256 _disputeID) external view override returns (DisputeStatus) {
        require(_disputeID < disputes.length, 'Invalid dispute ID');
        return disputes[_disputeID].status;
    }

    function currentRuling(uint256 _disputeID) external view override returns (uint256) {
        require(_disputeID < disputes.length, 'Invalid dispute ID');
        return disputes[_disputeID].ruling;
    }

    // Test helper functions
    function giveRuling(uint256 _disputeID, uint256 _ruling) external {
        require(_disputeID < disputes.length, 'Invalid dispute ID');

        Dispute storage dispute = disputes[_disputeID];
        require(_ruling <= dispute.choices, 'Invalid ruling');

        dispute.ruling = _ruling;
        dispute.status = DisputeStatus.Solved;

        dispute.arbitrable.rule(_disputeID, _ruling);
    }

    function setDisputeStatus(uint256 _disputeID, DisputeStatus _status) external {
        require(_disputeID < disputes.length, 'Invalid dispute ID');
        disputes[_disputeID].status = _status;
    }

    function setRuling(uint256 _disputeID, uint256 _ruling) external {
        require(_disputeID < disputes.length, 'Invalid dispute ID');
        disputes[_disputeID].ruling = _ruling;
        disputes[_disputeID].status = DisputeStatus.Solved;
    }

    function getDisputeCount() external view returns (uint256) {
        return disputes.length;
    }
}
