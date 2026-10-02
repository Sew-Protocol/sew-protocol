// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/core/BalanceAggregator.sol';
import '../../../contracts/core/MultiL2EscrowAggregator.sol';
import '../../../contracts/core/MulticallFallbackHandler.sol';
import '../../../contracts/core/MultiL2ViewAggregator.sol';
import '../../../contracts/interfaces/IMulticall3.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../mocks/MockMulticall3.sol';

contract BalanceAggregatorTest is Test {
    BalanceAggregator public agg;
    MockMulticall3 public mc;

    address owner = address(0xA1);
    address user = address(0xBEEF);
    address token = address(0x10);

    function setUp() public {
        mc = new MockMulticall3();
        vm.prank(owner);
        agg = new BalanceAggregator(address(mc));
    }

    function _result(bool success, uint256 balance) internal pure returns (IMulticall3.Result memory) {
        return IMulticall3.Result(success, success ? abi.encode(balance) : abi.encodePacked(hex''));
    }

    function test_aggregateBalances_success() public {
        IMulticall3.Result[] memory results = new IMulticall3.Result[](2);
        results[0] = _result(true, 100);
        results[1] = _result(true, 200);
        mc.setReturnData(results);

        address[] memory tokens = new address[](2);
        tokens[0] = token;
        tokens[1] = token;
        bytes[] memory calls = new bytes[](2);
        calls[0] = agg.encodeBalanceCall(token, user);
        calls[1] = agg.encodeBalanceCall(token, user);

        L2BalanceSnapshot memory snap = agg.aggregateBalances(user, tokens, calls);
        assertEq(snap.user, user);
        assertTrue(snap.healthy);
        assertEq(snap.balances.length, 2);
        assertEq(snap.balances[0].balance, 100);
        assertEq(snap.balances[1].balance, 200);
        assertTrue(snap.balances[0].success);
    }

    function test_aggregateBalances_markedUnhealthyOnFailure() public {
        IMulticall3.Result[] memory results = new IMulticall3.Result[](1);
        results[0] = _result(false, 0);
        mc.setReturnData(results);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        bytes[] memory calls = new bytes[](1);
        calls[0] = agg.encodeBalanceCall(token, user);

        L2BalanceSnapshot memory snap = agg.aggregateBalances(user, tokens, calls);
        assertFalse(snap.healthy);
        assertFalse(snap.balances[0].success);
    }

    function test_aggregateBalances_noCalls() public {
        address[] memory tokens = new address[](0);
        bytes[] memory calls = new bytes[](0);
        vm.expectRevert(BalanceAggregator.NoResults.selector);
        agg.aggregateBalances(user, tokens, calls);
    }

    function test_constructor_zeroMulticall() public {
        vm.prank(owner);
        vm.expectRevert(BalanceAggregator.InvalidMulticall3Address.selector);
        new BalanceAggregator(address(0));
    }

    function test_setMulticall3_onlyOwner() public {
        vm.prank(owner);
        agg.setMulticall3(address(0x1234));
        assertEq(address(agg.multicall3()), address(0x1234));

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        agg.setMulticall3(address(0x9999));
    }

    function test_encodingHelpers() public {
        bytes memory enc = agg.encodeBalanceCall(token, user);
        assertEq(agg.decodeBalanceResult(abi.encode(uint256(42))), 42);
        // encoded selector is balanceOf(address)
        assertEq(bytes4(enc), bytes4(keccak256('balanceOf(address)')));
    }
}

contract MultiL2EscrowAggregatorTest is Test {
    MultiL2EscrowAggregator public agg;
    MockMulticall3 public mc;

    address owner = address(0xA1);
    address user = address(0xBEEF);
    address escrow1 = address(0xE1);
    address escrow2 = address(0xE2);
    address usdc = address(0x11);

    function setUp() public {
        mc = new MockMulticall3();
        vm.prank(owner);
        agg = new MultiL2EscrowAggregator(address(mc), usdc);
    }

    function _result(bool success, bytes memory data) internal pure returns (IMulticall3.Result memory) {
        return IMulticall3.Result(success, data);
    }

    function _escrowQuery(uint256 chainId, address a) internal pure returns (EscrowQuery memory) {
        return EscrowQuery(chainId, a);
    }

    function test_queryEscrows_success() public {
        EscrowQuery[] memory q = new EscrowQuery[](2);
        q[0] = _escrowQuery(1, escrow1);
        q[1] = _escrowQuery(8453, escrow2);

        IMulticall3.Result[] memory results = new IMulticall3.Result[](4);
        results[0] = _result(true, abi.encode(100));
        results[1] = _result(true, abi.encode(true));
        results[2] = _result(true, abi.encode(250));
        results[3] = _result(true, abi.encode(true));
        mc.setReturnData(results);

        MultiL2EscrowSnapshot memory snap = agg.queryEscrows(user, q);
        assertEq(snap.user, user);
        assertEq(snap.totalLocked, 350);
        assertEq(snap.healthyChains, 2);
        assertEq(snap.escrows.length, 2);
        assertEq(snap.escrows[0].userBalance, 100);
        assertTrue(snap.escrows[0].active);
        assertTrue(snap.escrows[1].success);
    }

    function test_queryEscrows_partialFailure() public {
        EscrowQuery[] memory q = new EscrowQuery[](1);
        q[0] = _escrowQuery(1, escrow1);

        IMulticall3.Result[] memory results = new IMulticall3.Result[](2);
        results[0] = _result(true, abi.encode(100));
        results[1] = _result(false, abi.encodePacked(hex''));
        mc.setReturnData(results);

        MultiL2EscrowSnapshot memory snap = agg.queryEscrows(user, q);
        assertFalse(snap.escrows[0].success);
        assertEq(snap.healthyChains, 0);
        assertEq(snap.totalLocked, 0);
    }

    function test_queryEscrows_empty() public {
        EscrowQuery[] memory q = new EscrowQuery[](0);
        vm.expectRevert(MultiL2EscrowAggregator.EmptyEscrowList.selector);
        agg.queryEscrows(user, q);
    }

    function test_queryEscrowsWithUSDC() public {
        EscrowQuery[] memory q = new EscrowQuery[](1);
        q[0] = _escrowQuery(1, escrow1);

        IMulticall3.Result[] memory results = new IMulticall3.Result[](3);
        results[0] = _result(true, abi.encode(100));
        results[1] = _result(true, abi.encode(true));
        results[2] = _result(true, abi.encode(50)); // usdc balance
        mc.setReturnData(results);

        MultiL2EscrowSnapshot memory snap = agg.queryEscrowsWithUSDC(user, q);
        assertEq(snap.totalLocked, 100);
        assertEq(snap.healthyChains, 1);
    }

    function test_constructor_invalid() public {
        vm.prank(owner);
        vm.expectRevert(MultiL2EscrowAggregator.InvalidMulticallAddress.selector);
        new MultiL2EscrowAggregator(address(0), usdc);
    }

    function test_setters() public {
        vm.startPrank(owner);
        agg.setMulticall3(address(0x1234));
        assertEq(address(agg.multicall3()), address(0x1234));
        agg.setUSDCAddress(address(0x5678));
        assertEq(agg.usdcAddress(), address(0x5678));
        vm.stopPrank();

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        agg.setUSDCAddress(usdc);
    }
}

contract MulticallFallbackHandlerTest is Test {
    MulticallFallbackHandler public handler;
    MockMulticall3 public mc;

    address owner = address(0xA1);
    address fallbackAgg = address(0xF0);

    function setUp() public {
        mc = new MockMulticall3();
        vm.prank(owner);
        handler = new MulticallFallbackHandler(address(mc), fallbackAgg, 30);
    }

    function _call(address target, bytes memory data) internal pure returns (IMulticall3.Call3 memory) {
        return IMulticall3.Call3(target, true, data);
    }

    function _result(bool success) internal pure returns (IMulticall3.Result memory) {
        return IMulticall3.Result(success, abi.encode(success ? uint256(1) : uint256(0)));
    }

    function test_executeWithFallback_primarySuccess() public {
        vm.prank(owner);
        handler.addEndpoint(1, 'https://rpc', 1);

        IMulticall3.Result[] memory results = new IMulticall3.Result[](2);
        results[0] = _result(true);
        results[1] = _result(true);
        mc.setReturnData(results);

        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](2);
        calls[0] = _call(address(0x1), hex'');
        calls[1] = _call(address(0x2), hex'');

        (IMulticall3.Result[] memory out, bool usedFallback) = handler.executeWithFallback(calls, 1);
        assertFalse(usedFallback);
        assertEq(out.length, 2);
    }

    function test_executeWithFallback_lowSuccessRate() public {
        vm.prank(owner);
        handler.addEndpoint(1, 'https://rpc', 1);

        // 4 calls, only 1 success (< 4/2) -> low success rate -> fallback
        IMulticall3.Result[] memory results = new IMulticall3.Result[](4);
        results[0] = _result(true);
        results[1] = _result(false);
        results[2] = _result(false);
        results[3] = _result(false);
        mc.setReturnData(results);

        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](4);
        for (uint256 i = 0; i < 4; i++) {
            calls[i] = _call(address(uint160(0x1 + i)), hex'');
        }

        (IMulticall3.Result[] memory out, bool usedFallback) = handler.executeWithFallback(calls, 1);
        assertTrue(usedFallback);
        assertEq(out.length, 0);
    }

    function test_executeWithFallback_primaryReverts() public {
        vm.prank(owner);
        handler.addEndpoint(1, 'https://rpc', 1);

        // MockMulticall3 reverts when insufficient returnData set -> caught -> fallback
        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](2);
        calls[0] = _call(address(0x1), hex'');
        calls[1] = _call(address(0x2), hex'');

        vm.expectEmit();
        emit MulticallFallbackHandler.FallbackTriggered(1, 'primary_multicall_failed');
        (IMulticall3.Result[] memory out, bool usedFallback) = handler.executeWithFallback(calls, 1);
        assertTrue(usedFallback);
        assertEq(out.length, 0);
    }

    function test_executeWithFallback_endpointDisabled() public {
        vm.prank(owner);
        handler.addEndpoint(1, 'https://rpc', 1);
        vm.prank(owner);
        handler.disableEndpoint(1);

        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](0);
        vm.expectRevert(MulticallFallbackHandler.EndpointDisabled.selector);
        handler.executeWithFallback(calls, 1);
    }

    function test_executeWithFallback_unknownChainDisabled() public {
        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](0);
        vm.expectRevert(MulticallFallbackHandler.EndpointDisabled.selector);
        handler.executeWithFallback(calls, 999);
    }

    function test_endpointLifecycle() public {
        vm.startPrank(owner);
        handler.addEndpoint(1, 'https://rpc', 5);
        vm.stopPrank();

        assertTrue(handler.isEndpointHealthy(1));
        ChainEndpoint memory ep = handler.getEndpoint(1);
        assertEq(ep.rpcUrl, 'https://rpc');
        assertEq(ep.priority, 5);
        assertTrue(ep.enabled);

        vm.prank(owner);
        handler.disableEndpoint(1);
        assertFalse(handler.isEndpointHealthy(1));
        vm.expectRevert(MulticallFallbackHandler.EndpointDisabled.selector);
        handler.getEndpoint(1);

        vm.prank(owner);
        handler.enableEndpoint(1);
        assertTrue(handler.isEndpointHealthy(1));
    }

    function test_setters() public {
        vm.startPrank(owner);
        handler.setPrimaryMulticall(address(0x1234));
        assertEq(address(handler.primaryMulticall()), address(0x1234));
        handler.setFallbackConfig(address(0x9999), 60);
        (address fa, uint256 ft) = handler.fallbackConfig();
        assertEq(fa, address(0x9999));
        assertEq(ft, 60);
        vm.stopPrank();
    }

    function test_constructor_invalid() public {
        vm.prank(owner);
        vm.expectRevert(MulticallFallbackHandler.InvalidPrimaryMulticall.selector);
        new MulticallFallbackHandler(address(0), fallbackAgg, 30);
    }
}

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
