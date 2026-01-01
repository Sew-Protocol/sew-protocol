// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./UpgradeableBox.sol";

contract UpgradeableBoxV2 is UpgradeableBox {
    function version() external pure returns (string memory) {
        return "v2";
    }
}
