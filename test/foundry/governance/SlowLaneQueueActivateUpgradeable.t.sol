// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/shared/governance/SlowLaneQueueActivateUpgradeable.sol";

contract SlowLaneUpgradeableHarness is SlowLaneQueueActivateUpgradeable {
    PendingAddress public pendingAddress;
    PendingUint public pendingUint;

    function queueAddress(address newValue) external {
        _queueAddress(pendingAddress, newValue);
    }

    function activateAddress() external returns (address) {
        return _activateAddress(pendingAddress);
    }

    function queueUint(uint256 newValue) external {
        _queueUint(pendingUint, newValue);
    }

    function activateUint() external returns (uint256) {
        return _activateUint(pendingUint);
    }

    function getPendingAddr() external view returns (address value, uint64 eta, bool exists) {
        return getPendingAddress(pendingAddress);
    }

    function getPendingU() external view returns (uint256 value, uint64 eta, bool exists) {
        return getPendingUint(pendingUint);
    }
}

contract SlowLaneQueueActivateUpgradeableTest is Test {
    SlowLaneUpgradeableHarness public harness;
    address public user1 = address(0x1);
    uint256 public constant SLOW_DELAY = 7 days;

    function setUp() public {
        harness = new SlowLaneUpgradeableHarness();
    }

    function test_QueueAddress() public {
        harness.queueAddress(user1);
        (address val, uint64 eta, bool exists) = harness.getPendingAddr();
        
        assertEq(val, user1);
        assertEq(eta, block.timestamp + SLOW_DELAY);
        assertTrue(exists);
    }

    function test_ActivateAddress_Success() public {
        harness.queueAddress(user1);
        vm.warp(block.timestamp + SLOW_DELAY);
        address activated = harness.activateAddress();
        assertEq(activated, user1);
    }

    function test_ActivateAddress_NotReady() public {
        harness.queueAddress(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                SlowLaneQueueActivateUpgradeable.NotReady.selector,
                uint64(block.timestamp + SLOW_DELAY)
            )
        );
        harness.activateAddress();
    }

    function test_ActivateAddress_NoPending() public {
        vm.expectRevert(SlowLaneQueueActivateUpgradeable.NoPending.selector);
        harness.activateAddress();
    }

    function test_QueueAddress_Invalid() public {
        vm.expectRevert(SlowLaneQueueActivateUpgradeable.InvalidValue.selector);
        harness.queueAddress(address(0));
    }

    function test_QueueUint() public {
        harness.queueUint(123);
        (uint256 val, uint64 eta, bool exists) = harness.getPendingU();
        
        assertEq(val, 123);
        assertEq(eta, block.timestamp + SLOW_DELAY);
        assertTrue(exists);
    }

    function test_ActivateUint_Success() public {
        harness.queueUint(123);
        vm.warp(block.timestamp + SLOW_DELAY);
        uint256 activated = harness.activateUint();
        assertEq(activated, 123);
    }

    function test_ActivateUint_NotReady() public {
        harness.queueUint(123);
        vm.expectRevert(
            abi.encodeWithSelector(
                SlowLaneQueueActivateUpgradeable.NotReady.selector,
                uint64(block.timestamp + SLOW_DELAY)
            )
        );
        harness.activateUint();
    }

    function test_ActivateUint_NoPending() public {
        vm.expectRevert(SlowLaneQueueActivateUpgradeable.NoPending.selector);
        harness.activateUint();
    }

    function test_getPendingMethods() public {
        // Empty state
        (address v, uint64 e, bool ex) = harness.getPendingAddr();
        assertEq(v, address(0));
        assertEq(e, 0);
        assertFalse(ex);

        (uint256 vU, uint64 eU, bool exU) = harness.getPendingU();
        assertEq(vU, 0);
        assertEq(eU, 0);
        assertFalse(exU);

        harness.queueAddress(user1);
        (address val, uint64 eta, bool exists) = harness.getPendingAddr();
        assertEq(val, user1);
        assertTrue(exists);

        harness.queueUint(123);
        (uint256 valU, uint64 etaU, bool existsU) = harness.getPendingU();
        assertEq(valU, 123);
        assertTrue(existsU);
    }
}
