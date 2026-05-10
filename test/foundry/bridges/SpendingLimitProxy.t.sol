// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/bridges/SpendingLimitProxy.sol';
import '../../../contracts/bridges/DeferredFundingBridge.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';

/**
 * @title SpendingLimitProxyTest
 * @notice Comprehensive tests for SpendingLimitProxy.
 *
 * Coverage:
 *  - Construction and ownership (2-step transfer)
 *  - Deposit / withdraw (owner only)
 *  - Policy management: grant, revoke, pause/unpause, timelock queue
 *  - fundEscrow (Path A): happy path, all limit violations, rolling window resets
 *  - fundFromCreatorSignature (Path B): happy path, limit enforcement, bad sig
 *  - Wildcard (address(0)) policy fallback
 *  - Fuzz: spending amounts, window arithmetic
 */
contract SpendingLimitProxyTest is Test {
    // ─── Protocol stack ───────────────────────────────────────────────────────
    EscrowVault              public vault;
    ModuleSnapshotRegistry   public moduleRegistry;
    DefaultResolutionModule  public resolutionModule;
    DefaultReleaseStrategy   public releaseStrategy;
    CreateOps                public createOps;
    DisputeOps               public disputeOps;
    SettlementOps            public settlementOps;
    YieldOps                 public yieldOps;
    BondCollector            public bondCollector;
    DeferredFundingBridge    public bridge;

    // ─── Contracts under test ─────────────────────────────────────────────────
    SpendingLimitProxy public proxy;

    // ─── Tokens ───────────────────────────────────────────────────────────────
    ERC20Mock public usdc;
    ERC20Mock public dai;

    // ─── Actors ───────────────────────────────────────────────────────────────
    address public admin      = address(this);   // test contract = initial owner
    address public feeWallet  = address(0xFEE);
    address public resolver   = address(0xABCD);

    // Delegate: a hot wallet / agent  (no private key needed for Path A tests)
    address public delegate   = address(0x1111);

    // Creator for Path B: needs a key to sign EIP-712 messages
    uint256 public creatorPrivKey = 0xC0FFEE;
    address public creator;

    address public recipient  = address(0x3333);
    address public stranger   = address(0x9999);

    // ─── Policy defaults ──────────────────────────────────────────────────────
    uint128 constant MAX_PER_TX      = 500e18;
    uint128 constant DAILY_LIMIT     = 1_000e18;
    uint128 constant MONTHLY_LIMIT   = 10_000e18;
    uint32  constant MAX_TX_PER_HOUR = 5;

    uint256 constant FEE_BPS          = 100;   // 1 %
    uint256 constant FEE_DENOM        = 10_000;
    uint256 constant PROXY_FUND       = 100_000e18;
    uint256 constant MIN_ESCROW_AMOUNT = 1_000;   // vault minimum from SettingsValidationLibrary

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        creator = vm.addr(creatorPrivKey);

        // 1. Deploy ops infrastructure
        yieldOps      = new YieldOps(admin);
        disputeOps    = new DisputeOps(admin);
        settlementOps = new SettlementOps(admin);
        createOps     = new CreateOps(admin);
        bondCollector = new BondCollector(admin);
        moduleRegistry   = new ModuleSnapshotRegistry(admin);
        resolutionModule = new DefaultResolutionModule(admin, resolver);
        releaseStrategy  = new DefaultReleaseStrategy();

        // 2. Deploy vault
        vault = new EscrowVault(
            FEE_BPS,
            feeWallet,
            address(yieldOps),
            address(disputeOps),
            address(moduleRegistry)
        );

        // 3. Wire ops to vault
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));
        moduleRegistry.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), admin);
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));

        // 4. Register release strategy via 7-day slow lane
        moduleRegistry.grantRole(moduleRegistry.ROLE_TIMELOCK(), admin);
        moduleRegistry.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 7 days + 1);
        moduleRegistry.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        // 5. Deploy bridge and proxy
        bridge = new DeferredFundingBridge(address(vault), 'DeferredFundingBridge', '1');
        proxy  = new SpendingLimitProxy(address(bridge), admin);

        // 6. Deploy and distribute tokens
        usdc = new ERC20Mock('USDC', 'USDC', admin, 0);
        dai  = new ERC20Mock('DAI',  'DAI',  admin, 0);
        usdc.mint(admin, PROXY_FUND * 2);
        dai.mint(admin,  PROXY_FUND * 2);

        // 7. Fund proxy
        usdc.approve(address(proxy), PROXY_FUND);
        dai.approve(address(proxy),  PROXY_FUND);
        proxy.deposit(address(usdc), PROXY_FUND);
        proxy.deposit(address(dai),  PROXY_FUND);

        // 8. Grant default policy to delegate for USDC
        proxy.grantPolicy(delegate, address(usdc), _defaultPolicy());
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _defaultPolicy() internal pure returns (SpendingLimitProxy.Policy memory) {
        return SpendingLimitProxy.Policy({
            maxPerTx:     MAX_PER_TX,
            dailyLimit:   DAILY_LIMIT,
            monthlyLimit: MONTHLY_LIMIT,
            maxTxPerHour: MAX_TX_PER_HOUR,
            active:       true
        });
    }

    function _defaultDeadline() internal view returns (uint256) {
        return block.timestamp + 1 days;
    }

    function _netAmount(uint256 gross) internal pure returns (uint256) {
        return gross - (gross * FEE_BPS / FEE_DENOM);
    }

    function _fundEscrow(uint256 amount) internal returns (uint256 workflowId) {
        vm.prank(delegate);
        workflowId = proxy.fundEscrow(address(usdc), recipient, amount, _emptySettings());
    }

    function _emptySettings() internal pure returns (EscrowSettings memory s) {}

    function _signCommitment(
        address token,
        address _recipient,
        address releaser,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory sig) {
        bytes32 digest = bridge.commitmentDigest(token, _recipient, releaser, amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(creatorPrivKey, digest);
        sig = abi.encodePacked(r, s_, v);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_SetsImmutables() public view {
        assertEq(address(proxy.bridge()), address(bridge));
        assertEq(address(proxy.vault()),  address(vault));
        assertEq(proxy.owner(),           admin);
    }

    function test_constructor_RejectsZeroBridge() public {
        vm.expectRevert(SpendingLimitProxy.ZeroBridgeAddress.selector);
        new SpendingLimitProxy(address(0), admin);
    }

    function test_constructor_RejectsZeroOwner() public {
        vm.expectRevert(SpendingLimitProxy.ZeroOwnerAddress.selector);
        new SpendingLimitProxy(address(bridge), address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OWNERSHIP — 2-step transfer
    // ═══════════════════════════════════════════════════════════════════════════

    function test_ownership_TransferRequiresAcceptance() public {
        proxy.transferOwnership(stranger);
        assertEq(proxy.owner(),        admin);
        assertEq(proxy.pendingOwner(), stranger);
    }

    function test_ownership_AcceptSucceeds() public {
        proxy.transferOwnership(stranger);
        vm.prank(stranger);
        proxy.acceptOwnership();
        assertEq(proxy.owner(), stranger);
        assertEq(proxy.pendingOwner(), address(0));
    }

    function test_ownership_AcceptRevertsIfNotPending() public {
        proxy.transferOwnership(stranger);
        vm.prank(delegate); // wrong caller
        vm.expectRevert(SpendingLimitProxy.NotPendingOwner.selector);
        proxy.acceptOwnership();
    }

    function test_ownership_NonOwnerCannotTransfer() public {
        vm.prank(stranger);
        vm.expectRevert(SpendingLimitProxy.NotOwner.selector);
        proxy.transferOwnership(stranger);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPOSIT / WITHDRAW
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deposit_IncreasesProxyBalance() public {
        uint256 extra = 1_000e18;
        uint256 before = usdc.balanceOf(address(proxy));
        usdc.approve(address(proxy), extra);
        proxy.deposit(address(usdc), extra);
        assertEq(usdc.balanceOf(address(proxy)), before + extra);
    }

    function test_deposit_RevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SpendingLimitProxy.NotOwner.selector);
        proxy.deposit(address(usdc), 1e18);
    }

    function test_withdraw_DecreasesProxyBalance() public {
        uint256 before = usdc.balanceOf(address(proxy));
        proxy.withdraw(address(usdc), 500e18, admin);
        assertEq(usdc.balanceOf(address(proxy)), before - 500e18);
        assertEq(usdc.balanceOf(admin), 500e18 + usdc.balanceOf(admin) - (PROXY_FUND - before + 500e18));
    }

    function test_withdraw_RevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SpendingLimitProxy.NotOwner.selector);
        proxy.withdraw(address(usdc), 1e18, stranger);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POLICY — grantPolicy
    // ═══════════════════════════════════════════════════════════════════════════

    function test_grantPolicy_StoresAndEmits() public {
        proxy.grantPolicy(stranger, address(dai), _defaultPolicy());
        SpendingLimitProxy.Policy memory p = proxy.getPolicy(stranger, address(dai));
        assertTrue(p.active);
        assertEq(p.maxPerTx,     MAX_PER_TX);
        assertEq(p.dailyLimit,   DAILY_LIMIT);
        assertEq(p.monthlyLimit, MONTHLY_LIMIT);
        assertEq(p.maxTxPerHour, MAX_TX_PER_HOUR);
    }

    function test_grantPolicy_RevertsIfNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SpendingLimitProxy.NotOwner.selector);
        proxy.grantPolicy(delegate, address(usdc), _defaultPolicy());
    }

    function test_grantPolicy_AllowsDecreaseOnExistingPolicy() public {
        SpendingLimitProxy.Policy memory lower = SpendingLimitProxy.Policy({
            maxPerTx:     MAX_PER_TX / 2,
            dailyLimit:   DAILY_LIMIT / 2,
            monthlyLimit: MONTHLY_LIMIT,
            maxTxPerHour: MAX_TX_PER_HOUR,
            active:       true
        });
        proxy.grantPolicy(delegate, address(usdc), lower);
        assertEq(proxy.getPolicy(delegate, address(usdc)).maxPerTx, MAX_PER_TX / 2);
    }

    function test_grantPolicy_RevertsOnIncreaseMaxPerTx() public {
        SpendingLimitProxy.Policy memory higher = _defaultPolicy();
        higher.maxPerTx = MAX_PER_TX + 1;
        vm.expectRevert(SpendingLimitProxy.MustUsePolicyIncreaseQueue.selector);
        proxy.grantPolicy(delegate, address(usdc), higher);
    }

    function test_grantPolicy_RevertsOnIncreaseDaily() public {
        SpendingLimitProxy.Policy memory higher = _defaultPolicy();
        higher.dailyLimit = DAILY_LIMIT + 1;
        vm.expectRevert(SpendingLimitProxy.MustUsePolicyIncreaseQueue.selector);
        proxy.grantPolicy(delegate, address(usdc), higher);
    }

    function test_grantPolicy_RevertsOnIncreaseMonthly() public {
        SpendingLimitProxy.Policy memory higher = _defaultPolicy();
        higher.monthlyLimit = MONTHLY_LIMIT + 1;
        vm.expectRevert(SpendingLimitProxy.MustUsePolicyIncreaseQueue.selector);
        proxy.grantPolicy(delegate, address(usdc), higher);
    }

    function test_grantPolicy_RevertsOnIncreaseRate() public {
        SpendingLimitProxy.Policy memory higher = _defaultPolicy();
        higher.maxTxPerHour = MAX_TX_PER_HOUR + 1;
        vm.expectRevert(SpendingLimitProxy.MustUsePolicyIncreaseQueue.selector);
        proxy.grantPolicy(delegate, address(usdc), higher);
    }

    function test_revokePolicy_RemovesAccess() public {
        proxy.revokePolicy(delegate, address(usdc));
        assertFalse(proxy.getPolicy(delegate, address(usdc)).active);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POLICY — pause / unpause
    // ═══════════════════════════════════════════════════════════════════════════

    function test_pauseDelegate_BlocksAllSpending() public {
        proxy.pauseDelegate(delegate);
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitProxy.DelegatePausedError.selector, delegate)
        );
        proxy.fundEscrow(address(usdc), recipient, 100e18, _emptySettings());
    }

    function test_unpauseDelegate_RestoresAccess() public {
        proxy.pauseDelegate(delegate);
        proxy.unpauseDelegate(delegate);
        _fundEscrow(100e18);
        assertGt(usdc.balanceOf(recipient), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // POLICY — timelock queue
    // ═══════════════════════════════════════════════════════════════════════════

    function test_queuePolicyIncrease_CannotExecuteBeforeDelay() public {
        SpendingLimitProxy.Policy memory higher = _defaultPolicy();
        higher.maxPerTx = MAX_PER_TX * 2;
        proxy.queuePolicyIncrease(delegate, address(usdc), higher);

        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitProxy.TimelockNotExpired.selector,
                block.timestamp + proxy.INCREASE_TIMELOCK(),
                block.timestamp
            )
        );
        proxy.executePolicyIncrease(delegate, address(usdc));
    }

    function test_queuePolicyIncrease_ExecutesAfterDelay() public {
        SpendingLimitProxy.Policy memory higher = _defaultPolicy();
        higher.maxPerTx = MAX_PER_TX * 2;
        proxy.queuePolicyIncrease(delegate, address(usdc), higher);
        vm.warp(block.timestamp + proxy.INCREASE_TIMELOCK() + 1);
        proxy.executePolicyIncrease(delegate, address(usdc));
        assertEq(proxy.getPolicy(delegate, address(usdc)).maxPerTx, MAX_PER_TX * 2);
    }

    function test_queuePolicyIncrease_CanBeCancelled() public {
        SpendingLimitProxy.Policy memory higher = _defaultPolicy();
        higher.maxPerTx = MAX_PER_TX * 2;
        proxy.queuePolicyIncrease(delegate, address(usdc), higher);
        proxy.cancelPolicyIncrease(delegate, address(usdc));
        // Policy unchanged
        assertEq(proxy.getPolicy(delegate, address(usdc)).maxPerTx, MAX_PER_TX);
    }

    function test_executePolicyIncrease_RevertsIfNoPending() public {
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitProxy.NoPendingIncrease.selector, delegate, address(usdc))
        );
        proxy.executePolicyIncrease(delegate, address(usdc));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH A — fundEscrow happy path
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fundEscrow_RecipientReceivesNetAmount() public {
        uint256 gross = 300e18;
        _fundEscrow(gross);
        assertEq(usdc.balanceOf(recipient), _netAmount(gross));
    }

    function test_fundEscrow_ProxyBalanceDecreasesByGross() public {
        uint256 before = usdc.balanceOf(address(proxy));
        _fundEscrow(300e18);
        assertEq(usdc.balanceOf(address(proxy)), before - 300e18);
    }

    function test_fundEscrow_FeeGoesToFeeWallet() public {
        uint256 gross = 300e18;
        _fundEscrow(gross);
        // Fees accrue in vault.totalFeesPerToken; feeWallet balance unchanged until withdrawFees()
        assertEq(vault.totalFeesPerToken(address(usdc)), gross * FEE_BPS / FEE_DENOM);
    }

    function test_fundEscrow_ProxyHoldsNoResidualAllowance() public {
        _fundEscrow(300e18);
        assertEq(usdc.allowance(address(proxy), address(vault)), 0);
    }

    function test_fundEscrow_EmitsEscrowFunded() public {
        vm.prank(delegate);
        vm.expectEmit(true, true, true, false);
        emit SpendingLimitProxy.EscrowFunded(delegate, address(usdc), recipient, 300e18, 0);
        proxy.fundEscrow(address(usdc), recipient, 300e18, _emptySettings());
    }

    function test_fundEscrow_EmitsSpendRecorded() public {
        vm.prank(delegate);
        vm.expectEmit(true, true, false, false);
        emit SpendingLimitProxy.SpendRecorded(delegate, address(usdc), 300e18, 300e18, DAILY_LIMIT, 300e18, MONTHLY_LIMIT);
        proxy.fundEscrow(address(usdc), recipient, 300e18, _emptySettings());
    }

    function test_fundEscrow_TracksWindowCounters() public {
        _fundEscrow(300e18);
        SpendingLimitProxy.Window memory w = proxy.getWindow(delegate, address(usdc));
        assertEq(w.dailySpent,   300e18);
        assertEq(w.monthlySpent, 300e18);
        assertEq(w.txThisHour,   1);
    }

    function test_fundEscrow_ReturnedWorkflowIdIsNonZero() public {
        _fundEscrow(MIN_ESCROW_AMOUNT); // first escrow has wfId = 0 (array index)
        uint256 wfId = _fundEscrow(100e18); // second escrow has wfId = 1
        assertTrue(wfId > 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH A — limit violations
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fundEscrow_RevertsOnZeroToken() public {
        vm.prank(delegate);
        vm.expectRevert(SpendingLimitProxy.ZeroToken.selector);
        proxy.fundEscrow(address(0), recipient, 100e18, _emptySettings());
    }

    function test_fundEscrow_RevertsOnZeroRecipient() public {
        vm.prank(delegate);
        vm.expectRevert(SpendingLimitProxy.ZeroRecipient.selector);
        proxy.fundEscrow(address(usdc), address(0), 100e18, _emptySettings());
    }

    function test_fundEscrow_RevertsOnZeroAmount() public {
        vm.prank(delegate);
        vm.expectRevert(SpendingLimitProxy.ZeroAmount.selector);
        proxy.fundEscrow(address(usdc), recipient, 0, _emptySettings());
    }

    function test_fundEscrow_RevertsIfNoPolicyActive() public {
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitProxy.PolicyNotActive.selector, delegate, address(dai))
        );
        proxy.fundEscrow(address(dai), recipient, 100e18, _emptySettings());
    }

    function test_fundEscrow_RevertsOnExceedsPerTxLimit() public {
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitProxy.ExceedsPerTxLimit.selector, MAX_PER_TX + 1, MAX_PER_TX)
        );
        proxy.fundEscrow(address(usdc), recipient, MAX_PER_TX + 1, _emptySettings());
    }

    function test_fundEscrow_RevertsWhenDailyLimitExhausted() public {
        // Fill the daily limit with two transactions (500 + 500 = 1000)
        _fundEscrow(500e18);
        _fundEscrow(500e18);
        // Third transaction should fail
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitProxy.ExceedsDaily.selector, 1e18, 0)
        );
        proxy.fundEscrow(address(usdc), recipient, 1e18, _emptySettings());
    }

    function test_fundEscrow_RevertsWhenMonthlyLimitExhausted() public {
        // monthlyLimit = MAX_PER_TX so one tx exhausts the month while daily headroom remains
        SpendingLimitProxy.Policy memory tightMonth = SpendingLimitProxy.Policy({
            maxPerTx:     MAX_PER_TX,
            dailyLimit:   DAILY_LIMIT,
            monthlyLimit: MAX_PER_TX,    // 500e18 — exhausted by the first tx
            maxTxPerHour: MAX_TX_PER_HOUR,
            active:       true
        });
        proxy.grantPolicy(delegate, address(usdc), tightMonth);
        _fundEscrow(MAX_PER_TX); // monthlySpent == monthlyLimit; dailySpent still < dailyLimit
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitProxy.ExceedsMonthly.selector, 1e18, 0)
        );
        proxy.fundEscrow(address(usdc), recipient, 1e18, _emptySettings());
    }

    function test_fundEscrow_RevertsOnRateLimit() public {
        // Exhaust the hourly tx rate (MAX_TX_PER_HOUR = 5) with small amounts
        uint256 small = 10e18;
        for (uint256 i = 0; i < MAX_TX_PER_HOUR; i++) {
            _fundEscrow(small);
        }
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpendingLimitProxy.ExceedsRateLimit.selector,
                MAX_TX_PER_HOUR,
                MAX_TX_PER_HOUR
            )
        );
        proxy.fundEscrow(address(usdc), recipient, small, _emptySettings());
    }

    function test_fundEscrow_RevertsOnInsufficientProxyBalance() public {
        // Withdraw most of the proxy's USDC
        proxy.withdraw(address(usdc), PROXY_FUND - 1, admin);
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitProxy.InsufficientProxyBalance.selector, address(usdc), 100e18, 1)
        );
        proxy.fundEscrow(address(usdc), recipient, 100e18, _emptySettings());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH A — rolling window resets
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fundEscrow_DailyWindowResetsAfter24h() public {
        // Fill daily limit
        _fundEscrow(500e18);
        _fundEscrow(500e18);
        // Advance past 24h window
        vm.warp(block.timestamp + 25 hours);
        // Should succeed again
        uint256 wfId = _fundEscrow(500e18);
        assertTrue(wfId > 0);
    }

    function test_fundEscrow_HourlyRateResetsAfter1h() public {
        uint256 small = 10e18;
        for (uint256 i = 0; i < MAX_TX_PER_HOUR; i++) {
            _fundEscrow(small);
        }
        vm.warp(block.timestamp + 61 minutes);
        // Should succeed again (new hour)
        uint256 wfId = _fundEscrow(small);
        assertTrue(wfId > 0);
    }

    function test_fundEscrow_MonthlyWindowResetsAfter30Days() public {
        // Same tight policy: monthlyLimit = dailyLimit so two txs exhaust the month
        SpendingLimitProxy.Policy memory tightMonth = SpendingLimitProxy.Policy({
            maxPerTx:     MAX_PER_TX,
            dailyLimit:   DAILY_LIMIT,
            monthlyLimit: DAILY_LIMIT,
            maxTxPerHour: MAX_TX_PER_HOUR,
            active:       true
        });
        proxy.grantPolicy(delegate, address(usdc), tightMonth);
        _fundEscrow(500e18);
        _fundEscrow(500e18); // monthly exhausted
        // Advance past the 30-day rolling window
        vm.warp(block.timestamp + 30 days + 1);
        uint256 wfId = _fundEscrow(MAX_PER_TX); // wfId = 2 (two prior escrows)
        assertTrue(wfId > 0);
    }

    function test_fundEscrow_RollingWindowNotCalendarDay() public {
        // Send exactly at the limit
        _fundEscrow(500e18);
        _fundEscrow(500e18);
        // Advance 23h 59m — NOT a new day yet
        vm.warp(block.timestamp + 23 hours + 59 minutes);
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitProxy.ExceedsDaily.selector, 1e18, 0)
        );
        proxy.fundEscrow(address(usdc), recipient, 1e18, _emptySettings());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH A — view helpers
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getRemainingDaily_ReflectsSpend() public {
        uint256 spend = 300e18;
        _fundEscrow(spend);
        assertEq(proxy.getRemainingDaily(delegate, address(usdc)), DAILY_LIMIT - spend);
    }

    function test_getRemainingDaily_FullAfterReset() public {
        _fundEscrow(300e18);
        vm.warp(block.timestamp + 25 hours);
        assertEq(proxy.getRemainingDaily(delegate, address(usdc)), DAILY_LIMIT);
    }

    function test_getRemainingMonthly_ReflectsSpend() public {
        uint256 spend = 300e18;
        _fundEscrow(spend);
        assertEq(proxy.getRemainingMonthly(delegate, address(usdc)), MONTHLY_LIMIT - spend);
    }

    function test_getRemainingTxThisHour_ReflectsCount() public {
        _fundEscrow(10e18);
        _fundEscrow(10e18);
        assertEq(proxy.getRemainingTxThisHour(delegate, address(usdc)), MAX_TX_PER_HOUR - 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WILDCARD POLICY (token = address(0))
    // ═══════════════════════════════════════════════════════════════════════════

    function test_wildcardPolicy_AppliesToUnregisteredToken() public {
        // Register wildcard for delegate (no specific DAI policy)
        proxy.grantPolicy(delegate, address(0), _defaultPolicy());
        // DAI has no specific policy → falls back to wildcard
        vm.prank(delegate);
        proxy.fundEscrow(address(dai), recipient, 100e18, _emptySettings());
        assertGt(dai.balanceOf(recipient), 0);
    }

    function test_wildcardPolicy_SpecificPolicyTakesPrecedence() public {
        // Register wildcard with very tight limits
        SpendingLimitProxy.Policy memory tight = SpendingLimitProxy.Policy({
            maxPerTx:     1e18,
            dailyLimit:   1e18,
            monthlyLimit: 1e18,
            maxTxPerHour: 1,
            active:       true
        });
        proxy.grantPolicy(delegate, address(0), tight);
        // Specific USDC policy has MAX_PER_TX = 500e18 — should still work
        _fundEscrow(200e18);
        assertGt(usdc.balanceOf(recipient), 0);
    }

    function test_wildcardPolicy_IndependentWindowsPerToken() public {
        proxy.grantPolicy(delegate, address(0), _defaultPolicy());
        // Exhaust USDC daily
        _fundEscrow(500e18);
        _fundEscrow(500e18);
        // DAI should still have a fresh window
        vm.prank(delegate);
        uint256 wfId = proxy.fundEscrow(address(dai), recipient, 300e18, _emptySettings());
        assertTrue(wfId > 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH B — fundFromCreatorSignature
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fundFromSig_HappyPath_RecipientReceivesFunds() public {
        uint256 amount = 200e18;
        uint256 nonce  = 1;
        uint256 dl     = _defaultDeadline();
        bytes memory sig = _signCommitment(address(usdc), recipient, address(proxy), amount, nonce, dl);

        vm.prank(delegate);
        proxy.fundFromCreatorSignature(address(usdc), recipient, amount, nonce, dl, sig);

        assertEq(usdc.balanceOf(recipient), _netAmount(amount));
    }

    function test_fundFromSig_HappyPath_ProxyBalanceDecreases() public {
        uint256 amount = 200e18;
        uint256 before = usdc.balanceOf(address(proxy));
        bytes memory sig = _signCommitment(address(usdc), recipient, address(proxy), amount, 1, _defaultDeadline());
        vm.prank(delegate);
        proxy.fundFromCreatorSignature(address(usdc), recipient, amount, 1, _defaultDeadline(), sig);
        assertEq(usdc.balanceOf(address(proxy)), before - amount);
    }

    function test_fundFromSig_HappyPath_ProxyHoldsNoResidualAllowance() public {
        bytes memory sig = _signCommitment(address(usdc), recipient, address(proxy), 200e18, 1, _defaultDeadline());
        vm.prank(delegate);
        proxy.fundFromCreatorSignature(address(usdc), recipient, 200e18, 1, _defaultDeadline(), sig);
        assertEq(usdc.allowance(address(proxy), address(bridge)), 0);
    }

    function test_fundFromSig_HappyPath_TracksWindowCounters() public {
        uint256 amount = 200e18;
        bytes memory sig = _signCommitment(address(usdc), recipient, address(proxy), amount, 1, _defaultDeadline());
        vm.prank(delegate);
        proxy.fundFromCreatorSignature(address(usdc), recipient, amount, 1, _defaultDeadline(), sig);
        SpendingLimitProxy.Window memory w = proxy.getWindow(delegate, address(usdc));
        assertEq(w.dailySpent,   amount);
        assertEq(w.monthlySpent, amount);
        assertEq(w.txThisHour,   1);
    }

    function test_fundFromSig_RevertsOnDailyLimitViaPathB() public {
        // Exhaust daily via Path A, then attempt Path B
        _fundEscrow(500e18);
        _fundEscrow(500e18);
        bytes memory sig = _signCommitment(address(usdc), recipient, address(proxy), 1e18, 99, _defaultDeadline());
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(SpendingLimitProxy.ExceedsDaily.selector, 1e18, 0)
        );
        proxy.fundFromCreatorSignature(address(usdc), recipient, 1e18, 99, _defaultDeadline(), sig);
    }

    function test_fundFromSig_RevertsOnBadSignature() public {
        // A malformed (wrong-length) signature causes ECDSA.recover to revert
        bytes memory badSig = hex"deadbeef";
        vm.prank(delegate);
        vm.expectRevert();
        proxy.fundFromCreatorSignature(address(usdc), recipient, 200e18, 1, _defaultDeadline(), badSig);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CROSS-PATH — limits shared between Path A and Path B
    // ═══════════════════════════════════════════════════════════════════════════

    function test_limitsSharedAcrossPaths() public {
        // Spend half via Path A
        _fundEscrow(500e18);
        // Attempt Path B for the other half — should succeed
        bytes memory sig = _signCommitment(address(usdc), recipient, address(proxy), 500e18, 1, _defaultDeadline());
        vm.prank(delegate);
        proxy.fundFromCreatorSignature(address(usdc), recipient, 500e18, 1, _defaultDeadline(), sig);
        // Both windows reflect the full daily spend
        assertEq(proxy.getRemainingDaily(delegate, address(usdc)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUZZ
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_fundEscrow_AmountsWithinLimits(uint128 amount) public {
        amount = uint128(bound(uint256(amount), MIN_ESCROW_AMOUNT, MAX_PER_TX));
        _fundEscrow(amount);
        assertGt(usdc.balanceOf(recipient), 0);
    }

    function testFuzz_fundEscrow_DailyAccumulation(uint128 a, uint128 b) public {
        a = uint128(bound(uint256(a), MIN_ESCROW_AMOUNT, MAX_PER_TX));
        b = uint128(bound(uint256(b), MIN_ESCROW_AMOUNT, MAX_PER_TX));
        vm.assume(uint256(a) + uint256(b) <= DAILY_LIMIT);
        _fundEscrow(a);
        _fundEscrow(b);
        assertEq(proxy.getWindow(delegate, address(usdc)).dailySpent, uint256(a) + uint256(b));
    }
}
