// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowableERC20.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";

contract Test_BaseEscrow_test is Test {
    EscrowableERC20 token;
    YieldOps yieldOps;
    DisputeOps disputeOps;

    function setUp() public {
        // Deploy EscrowableERC20 with this contract as owner
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        token = new EscrowableERC20("Test Token", "TEST", 100, address(this), address(yieldOps), address(disputeOps));
    }

    function test_supports_IERC165_interface() public {
        // IERC165 id = 0x01ffc9a7
        bytes4 IERC165_ID = 0x01ffc9a7;
        assertTrue(token.supportsInterface(IERC165_ID));
    }

    function test_get_escrow_count_initially_zero() public {
        assertEq(token.getEscrowCount(), 0);
    }

    // Note: many BaseEscrow behaviors require a resolution module and governance slow-lane activation.
    // Full behavioral ports (createEscrow, resolve, dispute flows) require additional setup and are deferred.
}
