// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

contract RevertingReceiver {
    error ReceiveRejected();

    receive() external payable {
        revert ReceiveRejected();
    }
}
