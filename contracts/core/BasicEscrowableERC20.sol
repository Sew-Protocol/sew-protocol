// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './EscrowableERC20.sol';

contract BasicEscrowableERC20 is EscrowableERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    )
        EscrowableERC20(
            name,
            symbol,
            escrowFeeBps,
            feeAddress,
            yieldOpsAddress,
            disputeOpsAddress,
            moduleManagementAddress
        )
    {}

    function _depositYieldForEscrow(
        uint256,
        address,
        uint256
    ) internal override {}

    function _handleYieldAndGetActualAmount(
        uint256,
        address,
        uint256 amount
    ) internal override returns (uint256) {
        return amount;
    }
}
