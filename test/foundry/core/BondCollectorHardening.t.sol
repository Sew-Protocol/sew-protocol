// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/decentralized-resolution-module/IIncentiveModule.sol";

contract BondCollectorHardeningTest is Test {
    BondCollector public collector;
    ERC20Mock public token;
    address public owner = address(0xBAD);

    function setUp() public {
        collector = new BondCollector(owner);
        token = new ERC20Mock("Token", "TKN", address(this), 1000 ether);
    }

    function test_BondCollector_Recovery() public {
        token.transfer(address(collector), 100 ether);
        
        vm.startPrank(owner);
        collector.recoverERC20(address(token), owner, 100 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(owner), 100 ether, "Tokens should be recovered");
    }

    function test_BondCollector_CollectERC20_PullFixed() public {
        // Mock incentive module
        address incentiveMod = address(0x123);
        vm.mockCall(
            incentiveMod,
            abi.encodeWithSignature("recordAppealBond(uint256,address,address,uint256,address,uint8)"),
            abi.encode()
        );

        token.approve(address(collector), 100 ether);
        
        // This should now succeed because it pulls tokens from the caller (this contract)
        bytes32 role = collector.ROLE_ESCROW_CONTRACT();
        vm.prank(owner);
        collector.grantRole(role, address(this));
        
        bool success = collector.collectBond(
            0,
            IIncentiveModule(incentiveMod),
            100 ether,
            address(token),
            1,
            0,
            address(0),
            address(this),
            address(this)
        );
        
        assertTrue(success);
        assertEq(token.balanceOf(address(collector)), 100 ether, "Bond tokens should be held in collector");
    }
}
