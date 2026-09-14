// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import '../../../contracts/arbitration/KlerosArbitrableProxy.sol';
import '../../../contracts/arbitration/mocks/MockKlerosArbitrator.sol';

/// @notice Shared Kleros handoff fixture for escrow integration tests.
abstract contract KlerosHandoffFixture {
    function _deployKlerosHandoffProxy(
        address escrow,
        address admin,
        uint256 arbitrationCost
    ) internal returns (KlerosArbitrableProxy proxy, MockKlerosArbitrator arbitrator) {
        arbitrator = new MockKlerosArbitrator(arbitrationCost);
        proxy = new KlerosArbitrableProxy(address(arbitrator), admin);

        vmGrantTimelock(proxy, admin);
        proxy.registerKlerosHandoffEscrow(escrow);
    }

    function vmGrantTimelock(KlerosArbitrableProxy proxy, address admin) private {
        proxy.grantRole(proxy.ROLE_TIMELOCK(), admin);
    }

}
