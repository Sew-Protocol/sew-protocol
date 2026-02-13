// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './EscrowVault.sol';

contract BasicEscrowVault is EscrowVault {
    constructor(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) EscrowVault(
        escrowFeeBps,
        feeAddress,
        yieldOpsAddress,
        disputeOpsAddress,
        moduleManagementAddress
    ) {}

    function _depositYieldForEscrow(uint256,address,uint256) internal override {}
    function _handleYieldAndGetActualAmount(uint256,address,uint256 a) internal override returns (uint256) { return a; }
}
