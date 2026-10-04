// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/core/MultiL2ViewAggregator.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';

/// @notice Minimal fake vault exposing the exact view selectors MultiL2ViewAggregator reads.
contract MockViewVault {
    struct Entry {
        address token;
        address to;
        address from;
        address resolver;
        uint256 amount;
        uint64 autoRelease;
        uint64 autoCancel;
        EscrowState state;
        address releaseAddr;
    }

    Entry[] public escrows;
    mapping(uint256 => YieldPreset) public preset;
    mapping(address => uint256) public held;
    mapping(address => uint256) public fees;

    function push(
        address token,
        address to,
        address from,
        address resolver,
        uint256 amount,
        uint64 autoRelease,
        uint64 autoCancel,
        EscrowState state,
        address releaseAddr,
        YieldPreset yp
    ) external {
        escrows.push(Entry(token, to, from, resolver, amount, autoRelease, autoCancel, state, releaseAddr));
        preset[escrows.length - 1] = yp;
        held[token] += amount;
    }

    function getEscrowCount() external view returns (uint256) {
        return escrows.length;
    }

    function escrowTransfers(uint256 i) external view returns (
        address token,
        address to,
        address from,
        address disputeResolver,
        uint256 amountAfterFee,
        uint64 autoReleaseTime,
        uint64 autoCancelTime,
        EscrowState escrowState,
        SenderStatus,
        RecipientStatus
    ) {
        Entry storage e = escrows[i];
        return (e.token, e.to, e.from, e.resolver, e.amount, e.autoRelease, e.autoCancel, e.state, SenderStatus.NONE, RecipientStatus.NONE);
    }

    function escrowSettings(uint256 i) external view returns (
        address customResolver,
        address releaseAddress,
        YieldPreset yieldPreset,
        uint256 autoReleaseTime,
        uint256 autoCancelTime
    ) {
        Entry storage e = escrows[i];
        return (address(0), e.releaseAddr, preset[i], e.autoRelease, e.autoCancel);
    }

    function totalHeldInEscrowPerToken(address token) external view returns (uint256) {
        return held[token];
    }

    function totalFeesPerToken(address token) external view returns (uint256) {
        return fees[token];
    }
}

contract MultiL2ViewAggregatorTest is Test {
    MultiL2ViewAggregator public agg;
    MockViewVault public vault;

    address tokenA = address(0xAA);
    address alice = address(0xAB);
    address bob = address(0xAC);
    address resolver = address(0xAD);

    function setUp() public {
        vault = new MockViewVault();
        vault.push(tokenA, bob, alice, resolver, 500, 1000, 2000, EscrowState.PENDING, bob, YieldPreset.OFF);
        vault.push(tokenA, alice, bob, resolver, 700, 3000, 4000, EscrowState.PENDING, bob, YieldPreset.ENABLED);
        agg = new MultiL2ViewAggregator(address(vault));
    }

    function test_constructor_zeroVault() public {
        vm.expectRevert('ZeroVaultAddress');
        new MultiL2ViewAggregator(address(0));
    }

    function test_getEscrowSnapshot() public {
        MultiL2ViewAggregator.EscrowSnapshot memory s = agg.getEscrowSnapshot(0);
        assertEq(s.token, tokenA);
        assertEq(s.from, alice);
        assertEq(s.to, bob);
        assertEq(s.resolver, resolver);
        assertEq(s.amount, 500);
        assertEq(s.autoReleaseTime, 1000);
        assertEq(s.autoCancelTime, 2000);
        assertEq(uint(s.state), uint(EscrowState.PENDING));
    }

    function test_getEscrowSnapshot_invalidId() public {
        vm.expectRevert(abi.encodeWithSelector(MultiL2ViewAggregator.InvalidWorkflowId.selector, 99, uint256(2)));
        agg.getEscrowSnapshot(99);
    }

    function test_getSettingsSnapshot() public {
        MultiL2ViewAggregator.SettingsSnapshot memory s = agg.getSettingsSnapshot(1);
        assertEq(s.customResolver, address(0));
        assertEq(s.yieldPreset, uint8(YieldPreset.ENABLED));
        assertEq(s.autoReleaseTime, 3000);
        assertEq(s.autoCancelTime, 4000);
    }

    function test_getSettingsSnapshot_invalidId() public {
        vm.expectRevert(abi.encodeWithSelector(MultiL2ViewAggregator.InvalidWorkflowId.selector, 99, uint256(2)));
        agg.getSettingsSnapshot(99);
    }

    function test_totals() public {
        assertEq(agg.getTotalHeldPerToken(tokenA), 1200); // 500 + 700
        assertEq(agg.getTotalFeesPerToken(tokenA), 0);
        assertEq(agg.getEscrowCount(), 2);
    }

    function test_batchGetEscrowSnapshots() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        MultiL2ViewAggregator.EscrowSnapshot[] memory snaps = agg.batchGetEscrowSnapshots(ids);
        assertEq(snaps.length, 2);
        assertEq(snaps[0].amount, 500);
        assertEq(snaps[1].amount, 700);
    }

    function test_batchGetSettingsSnapshots() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        MultiL2ViewAggregator.SettingsSnapshot[] memory snaps = agg.batchGetSettingsSnapshots(ids);
        assertEq(snaps.length, 2);
        assertEq(snaps[0].customResolver, address(0));
        assertEq(snaps[1].customResolver, address(0));
    }

    function test_healthCheck() public {
        (bool healthy, uint256 escrowCount, uint256 lastEscrowId) = agg.healthCheck();
        assertTrue(healthy);
        assertEq(escrowCount, 2);
        assertEq(lastEscrowId, 1);
    }
}
