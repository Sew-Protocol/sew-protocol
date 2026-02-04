// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {EscrowableERC20} from '../../core/EscrowableERC20.sol';

/**
 * @title ReentrancyAttacker
 * @notice Mock contract to test reentrancy protection
 */
contract ReentrancyAttacker {
    EscrowableERC20 public target;
    uint256 public workflowId;
    bool public attacking;

    constructor(address _target) {
        target = EscrowableERC20(_target);
    }

    // function attack(uint256 _workflowId) external {
    //     workflowId = _workflowId;
    //     attacking = true;
    //     target.releaseAsDisputeResolver(_workflowId, bytes32(0));
    // }

    // // Receive function that tries to reenter
    // receive() external payable {
    //     if (attacking) {
    //         attacking = false;
    //         target.releaseAsDisputeResolver(workflowId, bytes32(0));
    //     }
    // }
}
