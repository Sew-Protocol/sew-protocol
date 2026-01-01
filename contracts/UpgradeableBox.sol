// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract UpgradeableBox is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    uint256 public value;

    event ValueSet(uint256 value);

    function initialize(address owner_, uint256 initialValue) public initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        value = initialValue;
        emit ValueSet(initialValue);
    }

    function setValue(uint256 newValue) external onlyOwner {
        value = newValue;
        emit ValueSet(newValue);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
