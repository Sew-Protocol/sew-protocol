// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import {MockFeeOnTransfer} from '../../../contracts/mocks/MockFeeOnTransfer.sol';
import {MockNonStandardERC20} from '../../../contracts/mocks/MockNonStandardERC20.sol';
import {MockRebasingToken} from '../../../contracts/mocks/MockRebasingToken.sol';

contract ERC20EdgeCasesTest is Test {
    function setUp() public {}

    function testFeeOnTransfer_behavesAsExpected() public {
        address feeRecipient = address(0xBEEF);
        MockFeeOnTransfer token = new MockFeeOnTransfer(
            'FeeToken',
            'FEE',
            address(this),
            1_000_000 ether,
            100,
            feeRecipient
        );

        // transfer 100 tokens to addr1: feeBps = 100 -> 1% fee => recipient gets 99, feeRecipient gets 1
        address recipient = address(0xCAFE);
        token.transfer(recipient, 100 ether);
        assertEq(token.balanceOf(recipient), 99 ether);
        assertEq(token.balanceOf(feeRecipient), 1 ether);
    }

    function testNonStandardToken_transferDoesNotReturnBool() public {
        MockNonStandardERC20 token = new MockNonStandardERC20(
            'NS',
            'NS',
            address(this),
            1_000 ether
        );
        address recipient = address(0xDEAD);

        // The mock intentionally does not return a bool from transfer. Ensure transfer updates balances.
        token.transfer(recipient, 10 ether);
        assertEq(token.balanceOf(recipient), 10 ether);
        assertEq(token.balanceOf(address(this)), 990 ether);
    }

    function testRebasingToken_rebaseIncreasesSupply() public {
        MockRebasingToken token = new MockRebasingToken('REB', 'REB', address(this), 1_000 ether);
        uint256 supplyBefore = token.totalSupply();
        token.rebase(address(this), 500 ether);
        uint256 supplyAfter = token.totalSupply();
        assertEq(supplyAfter, supplyBefore + 500 ether);
    }

    // TODO: integrate these mocks with the system contracts (Escrow, Vault, etc.) and verify
    // acceptance/rejection policies. Add more thorough edge-case tests per TESTING_ADHERENCE_PLAN.
}
