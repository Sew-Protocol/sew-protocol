// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {UpgradeableBox} from "../../contracts/UpgradeableBox.sol";
import {UpgradeableBoxV2} from "../../contracts/UpgradeableBoxV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UpgradeableBoxFoundryTest is Test {
    address owner = address(0xA11CE);

    function testUUPSProxyFlow() public {
        UpgradeableBox impl = new UpgradeableBox();
        bytes memory init = abi.encodeCall(UpgradeableBox.initialize, (owner, 123));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);

        UpgradeableBox box = UpgradeableBox(address(proxy));
        assertEq(box.value(), 123);

        vm.prank(owner);
        box.setValue(777);
        assertEq(box.value(), 777);

        UpgradeableBoxV2 impl2 = new UpgradeableBoxV2();
        vm.prank(owner);
        box.upgradeToAndCall(address(impl2), "");
        assertEq(UpgradeableBoxV2(address(proxy)).version(), "v2");
    }

    function testTransparentProxyFlow() public {
        UpgradeableBox impl = new UpgradeableBox();
        ProxyAdmin admin = new ProxyAdmin(owner);

        // For TransparentProxy, the ProxyAdmin should be the owner of the implementation
        // so it can authorize upgrades. Initialize with ProxyAdmin as owner.
        bytes memory init = abi.encodeCall(UpgradeableBox.initialize, (address(admin), 123));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), address(admin), init);

        UpgradeableBox box = UpgradeableBox(address(proxy));
        assertEq(box.value(), 123);

        // Set value using the ProxyAdmin as owner (since that's who owns the implementation)
        vm.prank(address(admin));
        box.setValue(555);
        assertEq(box.value(), 555);

        UpgradeableBoxV2 impl2 = new UpgradeableBoxV2();
        // For TransparentProxy, upgrades go through ProxyAdmin
        // The ProxyAdmin owner calls upgrade through ProxyAdmin
        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(impl2), "");
        assertEq(UpgradeableBoxV2(address(proxy)).version(), "v2");
    }
}
