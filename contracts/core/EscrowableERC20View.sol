// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './EscrowViewContract.sol';
import './EscrowableERC20.sol';
import './ModuleSnapshotRegistry.sol';

/**
 * @title EscrowableERC20View
 * @notice View contract for EscrowableERC20-specific getters
 * @dev Extends EscrowViewContract to add EscrowableERC20-specific read functions
 */
contract EscrowableERC20View is EscrowViewContract {
    constructor(address _escrowContract) EscrowViewContract(_escrowContract) {}

    function totalHeldInEscrow() external view returns (uint256) {
        return EscrowableERC20(address(escrowContract)).totalHeldInEscrow();
    }

    function totalFees() external view returns (uint256) {
        return EscrowableERC20(address(escrowContract)).totalFees();
    }

    function moduleManagement() external view returns (ModuleSnapshotRegistry) {
        return EscrowableERC20(address(escrowContract)).moduleManagement();
    }
}
