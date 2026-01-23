// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/governance/SlowLaneQueueActivate.sol";

// Harness contract to expose internal functions
contract SlowLaneHarness is SlowLaneQueueActivate {
    PendingAddress public pendingAddress;
    PendingUint public pendingUint;

    event AddressQueued(address indexed oldValue, address indexed newValue, uint64 eta);
    event AddressActivated(address indexed oldValue, address indexed newValue);
    event UintQueued(uint256 indexed oldValue, uint256 indexed newValue, uint64 eta);
    event UintActivated(uint256 indexed oldValue, uint256 indexed newValue);

    function queueAddress(address newValue) external {
        _queueAddress(pendingAddress, newValue);
        emit AddressQueued(address(0), newValue, pendingAddress.eta);
    }

    function activateAddress() external returns (address) {
        address val = _activateAddress(pendingAddress);
        emit AddressActivated(address(0), val);
        return val;
    }

    function queueUint(uint256 newValue) external {
        _queueUint(pendingUint, newValue);
        emit UintQueued(0, newValue, pendingUint.eta);
    }

    function activateUint() external returns (uint256) {
        uint256 val = _activateUint(pendingUint);
        emit UintActivated(0, val);
        return val;
    }

    function getPendingAddr() external view returns (address value, uint64 eta, bool exists) {
        return getPendingAddress(pendingAddress);
    }

    function getPendingU() external view returns (uint256 value, uint64 eta, bool exists) {
        return getPendingUint(pendingUint);
    }
}

contract SlowLaneQueueActivateTest is Test {
    SlowLaneHarness public harness;
    address public user1 = address(0x1);
    uint256 public constant SLOW_DELAY = 7 days;

    function setUp() public {
        harness = new SlowLaneHarness();
    }

    function test_QueueAddress() public {
        harness.queueAddress(user1);
        (address val, uint64 eta, bool exists) = harness.getPendingAddr();
        
        assertEq(val, user1);
        assertEq(eta, block.timestamp + SLOW_DELAY);
        assertTrue(exists);
    }

    function test_QueueAddress_RevertZero() public {
        vm.expectRevert(SlowLaneQueueActivate.InvalidValue.selector);
        harness.queueAddress(address(0));
    }

    function test_ActivateAddress_Success() public {
        harness.queueAddress(user1);
        
        vm.warp(block.timestamp + SLOW_DELAY);
        
        address activated = harness.activateAddress();
        assertEq(activated, user1);

        (address val, uint64 eta, bool exists) = harness.getPendingAddr();
        assertEq(val, address(0));
        assertEq(eta, 0);
        assertFalse(exists);
    }

    function test_ActivateAddress_RevertNoPending() public {
        vm.expectRevert(SlowLaneQueueActivate.NoPending.selector);
        harness.activateAddress();
    }

    function test_ActivateAddress_RevertNotReady() public {
        harness.queueAddress(user1);
        
        (, uint64 eta,) = harness.getPendingAddr();
        vm.expectRevert(abi.encodeWithSelector(SlowLaneQueueActivate.NotReady.selector, eta));
        harness.activateAddress();
    }

    function test_QueueUint() public {
        uint256 newVal = 123;
        harness.queueUint(newVal);
        (uint256 val, uint64 eta, bool exists) = harness.getPendingU();
        
        assertEq(val, newVal);
        assertEq(eta, block.timestamp + SLOW_DELAY);
        assertTrue(exists);
    }

    function test_ActivateUint_Success() public {
        uint256 newVal = 123;
        harness.queueUint(newVal);
        
        vm.warp(block.timestamp + SLOW_DELAY);
        
        uint256 activated = harness.activateUint();
        assertEq(activated, newVal);

        (uint256 val, uint64 eta, bool exists) = harness.getPendingU();
        assertEq(val, 0);
        assertEq(eta, 0);
        assertFalse(exists);
    }

    function test_ActivateUint_RevertNoPending() public {
        vm.expectRevert(SlowLaneQueueActivate.NoPending.selector);
        harness.activateUint();
    }

    function test_ActivateUint_RevertNotReady() public {
        harness.queueUint(123);
        
        (, uint64 eta,) = harness.getPendingU();
        vm.expectRevert(abi.encodeWithSelector(SlowLaneQueueActivate.NotReady.selector, eta));
        harness.activateUint();
    }
}
