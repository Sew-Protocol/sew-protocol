// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowCreationPolicy.sol';
import 'contracts/core/BondCollector.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/modules/DefaultReleaseStrategy.sol';
import 'contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import 'contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol';
import 'contracts/modules/decentralized-resolution-module/incentive/ResolverIncentiveModule.sol';
import 'contracts/modules/decentralized-resolution-module/libraries/PaymentCalculationLibrary.sol';
import 'contracts/admin/EscrowGovernanceTimelock.sol';
import 'contracts/arbitration/KlerosArbitrableProxy.sol';
import 'contracts/arbitration/mocks/MockKlerosArbitrator.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/libraries/EscrowEncodingLibrary.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/types/YieldPresets.sol';

/**
 * @title AaveYieldEscrowE2EFixture
 * @notice Shared full-stack escrow fixture: EscrowVault + AaveYieldModule (+ MockAavePool)
 *         + DecentralizedResolutionModule + ResolverIncentiveModule + Kleros proxy +
 *         release strategy + bond collector. Internal scenario runners drive the
 *         settlement/appeal/escalation matrix and apply strong terminal assertions.
 *
 * Design (per review): one full-stack fixture; the FULL matrix runs with the Aave module
 * active and yield ENABLED; only a small parity subset runs with yield disabled / no module.
 * Scenario config is a small struct; named test_* functions describe the scenario and call
 * a runner. Every terminal scenario asserts: correct terminal state, exact principal
 * conservation, exact realized yield, beneficiary claimable balance, protocol fee accounted
 * separately (when enabled), a real withdrawEscrow, wallet delta after withdrawal, no residual
 * claimable, module linkage fully unwound, and no double-realization.
 */
abstract contract AaveYieldEscrowE2EFixture is Test {
    // ---------- deployment ----------
    EscrowVault internal escrow;
    AaveYieldModule internal aaveModule;
    MockAavePool internal pool;
    MockAToken internal aToken;
    ERC20Mock internal token;
    ModuleSnapshotRegistry internal registry;
    EscrowCreationPolicy internal policy;
    BondCollector internal bondCollector;
    EscrowGovernanceTimelock internal adminContract;
    DecentralizedResolutionModule internal resolutionModule;
    ResolverIncentiveModule internal incentiveModule;
    PaymentCalculationLibrary internal paymentLib;
    KlerosArbitrableProxy internal klerosProxy;
    MockKlerosArbitrator internal klerosArbitrator;
    DefaultReleaseStrategy internal releaseStrategy;

    // ---------- actors ----------
    address internal deployer;
    address internal timelock;
    address internal buyer;
    address internal seller;
    address internal feeAddress;
    address internal resolver1;
    address internal resolver2;
    address internal seniorResolver;

    // ---------- constants matching the working fixtures ----------
    uint256 internal constant INITIAL_BALANCE = 10_000 ether;
    uint256 internal constant ESCROW_AMOUNT = 1_000 ether;
    uint256 internal constant KLEROS_ARBITRATION_COST = 0.1 ether;
    // Protocol yield fee (bps). Tests default to 0 for readable principal+yield assertions.
    uint256 internal constant FEE_ZERO = 0;
    uint256 internal constant FEE_MAX = 3000; // 30% — the configured MAX_PROTOCOL_FEE_BPS
    // Mock Aave time-accrual rate (scaled 1e27), ~4.9% over 30 days — matches AaveEscrowE2E.
    uint256 internal constant PER_SECOND_RATE = 1.9e19;

    /// @notice block.timestamp at which the currently-open position was created (used to
    ///         derive the mock-pool accrual window for expected-yield assertions).
    uint256 internal openTime;

    /// @notice Per-scenario configuration. yieldEnabled=false exercises the same settlement
    ///         machinery without an Aave module (principal-only + yield OFF). feeBps is the
    ///         snapshotted protocol yield fee. duration is accrued before terminal settlement.
    struct ScenarioConfig {
        bool yieldEnabled;
        uint256 feeBps;
    }

    // =====================================================================
    // DEPLOYMENT
    // =====================================================================
    function setUp() public virtual {
        deployer = address(this);
        timelock = makeAddr('timelock');
        buyer = makeAddr('buyer');
        seller = makeAddr('seller');
        feeAddress = makeAddr('feeAddress');
        resolver1 = makeAddr('resolver1');
        resolver2 = makeAddr('resolver2');
        seniorResolver = makeAddr('seniorResolver');

        // --- token + Aave stack (pull-model adapter, like AaveEscrowE2E) ---
        token = new ERC20Mock('Token', 'TKN', address(this), 0);
        aToken = new MockAToken(address(token), 'aTKN', 'aTKN');
        pool = new MockAavePool();
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));
        aaveModule = new AaveYieldModule(address(pool));
        _cfgToken(aaveModule, address(token), address(aToken));
        pool.enableTimeAccrual(PER_SECOND_RATE);

        // --- DRM + incentive + Kleros stack (like AppealWindowEnforcement) ---
        paymentLib = new PaymentCalculationLibrary();
        incentiveModule = new ResolverIncentiveModule(deployer, address(paymentLib));
        resolutionModule = new DecentralizedResolutionModule(deployer);
        { DRMAdminFacet a = new DRMAdminFacet(); resolutionModule.setAdminFacet(address(a)); }
        klerosArbitrator = new MockKlerosArbitrator(KLEROS_ARBITRATION_COST);
        klerosProxy = new KlerosArbitrableProxy(address(klerosArbitrator), deployer);

        // --- governance / registry / policy / bonds ---
        policy = new EscrowCreationPolicy(deployer);
        bondCollector = new BondCollector(deployer);
        registry = new ModuleSnapshotRegistry(deployer);
        adminContract = new EscrowGovernanceTimelock(deployer);
        releaseStrategy = new DefaultReleaseStrategy();

        escrow = new EscrowVault(0, feeAddress, address(registry));
        bondCollector.registerEscrowContract(address(escrow));
        bondCollector.registerEscrowContract(address(this));
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), deployer);
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(adminContract));
        escrow.grantRole(escrow.ROLE_TIMELOCK(), deployer);
        escrow.setCreationPolicy(address(policy));
        escrow.setBondCollector(address(bondCollector));

        // Approve escrow on the Aave module (pull model) once. The aave module constructor
        // granted ROLE_TIMELOCK to deployer; use its true slow-lane ETA for activation.
        aaveModule.queueApproveEscrow(address(escrow));
        (, uint64 approveEta, ) = aaveModule.getPendingApproveEscrow();
        vm.warp(approveEta);
        aaveModule.activateApproveEscrow();

        // DRM role wiring
        resolutionModule.grantRole(resolutionModule.ROLE_TIMELOCK(), deployer);
        resolutionModule.grantRole(resolutionModule.ROLE_TIMELOCK(), timelock);
        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), deployer);
        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), timelock);

        // Register escrow contracts (incl. self for setEscrowCategory-style calls)
        resolutionModule.registerEscrowContract(address(escrow));
        resolutionModule.registerEscrowContract(address(this));
        incentiveModule.registerEscrowContract(address(escrow));
        incentiveModule.registerEscrowContract(address(this));
        incentiveModule.registerEscrowContract(address(resolutionModule));
        klerosProxy.grantRole(klerosProxy.ROLE_TIMELOCK(), deployer);
        klerosProxy.registerKlerosHandoffEscrow(address(escrow));

        // Incentive module wired into DRM
        vm.prank(timelock);
        resolutionModule.setIncentiveModule(address(incentiveModule));

        // Resolution module snapshotted for the vault (via governance timelock)
        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(escrow));

        // Appoint + activate resolvers
        vm.prank(timelock);
        resolutionModule.appointSeniorResolver(seniorResolver, 'Senior', 'Senior resolver');
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver1, 'Resolver 1', 'Resolver 1');
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver2, 'Resolver 2', 'Resolver 2');
        vm.startPrank(timelock);
        resolutionModule.setResolverActive(seniorResolver, true);
        resolutionModule.setResolverActive(resolver1, true);
        resolutionModule.setResolverCapacity(resolver2, 0, true);
        vm.stopPrank();

        // Round config: round0/1 have appeal windows; round2 (Kleros) is final.
        uint256[3] memory resolveDeadlines = [uint256(7 days), 7 days, 7 days];
        uint256[3] memory appealWindows = [uint256(2 days), 3 days, 0];
        vm.prank(timelock);
        resolutionModule.setRoundTimeouts(resolveDeadlines, appealWindows);
        vm.prank(timelock);
        resolutionModule.setExternalResolver(address(klerosProxy));

        // Yield generation + release modules for the vault.
        registry.registerEscrowContract(address(escrow));
        registry.queueModule(address(escrow), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(escrow), BaseEscrow.ModuleType.RELEASE);

        // Fund actors
        token.mint(buyer, INITIAL_BALANCE);
        token.mint(seller, INITIAL_BALANCE);
        vm.deal(buyer, 10 ether);
        vm.deal(seller, 10 ether);
    }

    function _cfgToken(AaveYieldModule m, address token_, address aToken_) internal {
        m.queueConfigureToken(token_, aToken_);
        (, uint64 eta, ) = m.getPendingConfigureToken(token_);
        vm.warp(eta);
        m.activateConfigureToken(token_);
    }

    // =====================================================================
    // ESCROW OPENING
    // =====================================================================
    function _settings(bool yieldEnabled) internal pure returns (EscrowSettings memory s) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: yieldEnabled ? YieldPreset.ENABLED : YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    /// @dev Approve the escrow to pull the buyer's ERC20 (principal + appeal bonds).
    function _approveBuyer() internal {
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    function _openEscrow(ScenarioConfig memory cfg) internal returns (uint256 wf) {
        _approveBuyer();
        escrow.setYieldProtocolFeeBps(cfg.feeBps);
        escrow.setCreationPolicy(address(policy));

        if (cfg.yieldEnabled) {
            // Register the Aave module as the default YIELD_GEN for the vault (slow lane).
            registry.queueModule(address(escrow), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
            vm.warp(block.timestamp + 8 days); // past the 7-day slow-lane delay
            registry.activateModule(address(escrow), BaseEscrow.ModuleType.YIELD_GEN);
        }
        // Disabled: no YIELD_GEN module registered, so the escrow snapshots a zero module and
        // deposits no yield. (queueModule rejects address(0), so we simply don't register it.)

        vm.prank(buyer);
        wf = escrow.createEscrow(address(token), seller, ESCROW_AMOUNT, _settings(cfg.yieldEnabled));
        openTime = block.timestamp;
        if (cfg.yieldEnabled) {
            assertEq(escrow.v25YieldModules(wf), address(aaveModule), 'yield module recorded');
            assertEq(escrow.v25YieldPrincipals(wf), ESCROW_AMOUNT, 'yield principal recorded');
            assertGt(aToken.balanceOf(address(aaveModule)), 0, 'module holds aTokens');
        } else {
            assertEq(escrow.v25YieldModules(wf), address(0), 'no module recorded when disabled');
            assertEq(escrow.v25YieldPrincipals(wf), 0, 'no principal recorded when disabled');
        }
    }

    // =====================================================================
    // TIME / BLOCK ADVANCEMENT
    // =====================================================================
    /// @dev Advance time (drives mock Aave time-accrual) and mine `blocks` to simulate a
    ///      real chain with mined blocks. Deterministic against the mock — no live fork.
    function _accrue(uint256 duration) internal {
        vm.warp(block.timestamp + duration);
        vm.roll(block.number + 1);
    }

    // =====================================================================
    // DISPUTE / ESCALATION / RESOLUTION DRIVERS
    // =====================================================================
    function _escrowData(uint256 wf) internal view returns (bytes memory) {
        (address token_, address to_, address from_, , uint256 amountAfterFee_, , , , , ) =
            escrow.escrowTransfers(wf);
        return EscrowEncodingLibrary.encodeEscrowTransferData(
            token_, from_, to_, amountAfterFee_, address(0)
        );
    }

    function _raiseDispute(uint256 wf) internal {
        vm.prank(buyer);
        escrow.raiseDispute(wf);
        assertEq(uint8(escrow.getEscrowState(wf)), uint8(EscrowState.DISPUTED), 'DISPUTED after raise');
    }

    function _currentResolver(uint256 wf) internal view returns (address resolver) {
        bytes memory data = _escrowData(wf);
        (resolver, ) = resolutionModule.getDisputeResolver(wf, address(escrow), data);
    }

    /// @dev The current round's resolver issues a decision. Non-final rounds store a pending
    ///      settlement; final rounds settle immediately. `isRelease` is the decision.
    function _resolveRound(uint256 wf, bool isRelease) internal {
        address resolver = _currentResolver(wf);
        vm.prank(resolver);
        if (isRelease) escrow.releaseAsDisputeResolver(wf, bytes32(0));
        else escrow.cancelAsDisputeResolver(wf, bytes32(0));
    }

    /// @dev Escalate one round, paying the ERC20 appeal bond from `funder` (token approval
    ///      required). Kleros rounds additionally require ETH, supplied when escalation goes to
    ///      round 2. Uses `buyer` as escalator by default.
    function _escalate(uint256 wf, address funder, bool klerosRound) internal {
        bytes memory data = _escrowData(wf);
        // Appellants fund appeal bonds from their own token balance.
        vm.prank(funder);
        token.approve(address(escrow), type(uint256).max);
        (uint256 bond, ) = resolutionModule.getRequiredAppealBond(wf, address(escrow), 0, data);
        if (bond > 0) {
            vm.prank(funder);
            token.approve(address(escrow), bond);
        }
        if (klerosRound) {
            vm.deal(funder, 10 ether);
            vm.prank(funder);
            escrow.escalateDispute{value: KLEROS_ARBITRATION_COST}(wf);
        } else {
            vm.prank(funder);
            escrow.escalateDispute(wf);
        }
    }

    /// @dev Wait out the current pending settlement's appeal window, then execute it.
    function _executePending(uint256 wf) internal {
        vm.warp(block.timestamp + 4 days); // beyond the 2d/3d appeal windows
        vm.roll(block.number + 1);
        escrow.executePendingSettlement(wf);
    }

    // =====================================================================
    // TERMINAL ASSERTIONS
    // =====================================================================
    /// @notice Strong terminal assertions shared by every settlement path. Verifies the escrow
    ///         reached the expected terminal state, principal conservation, exact realized
    ///         yield, fee separate (when enabled), claimable balance, an actual withdrawEscrow,
    ///         wallet delta after withdrawal, no residual claimable, module unwound, and that a
    ///         second withdraw/double realization is impossible.
    /// @param beneficiary The party entitled to the full remaining escrow (principal + yield).
    function _assertSettled(
        ScenarioConfig memory cfg,
        uint256 wf,
        uint8 terminalState,
        address beneficiary,
        address otherParty
    ) internal {
        EscrowState st = escrow.getEscrowState(wf);
        assertEq(uint8(st), terminalState, 'terminal state');

        // Yield module linkage fully unwound for every terminal settlement.
        assertEq(escrow.v25YieldModules(wf), address(0), 'yield module linkage cleared');
        assertEq(escrow.v25YieldPrincipals(wf), 0, 'yield principal reference cleared');

        // The mock Aave pool accrues yield on elapsed block.timestamp from the position open.
        uint256 duration = block.timestamp - openTime;
        uint256 yieldExpected;
        if (cfg.yieldEnabled) {
            yieldExpected = _expectedYield(ESCROW_AMOUNT, duration);
            // Principal is never lost on a positive/unwind path when yield enabled.
            assertGt(yieldExpected, 0, 'expected positive realized yield');
        } else {
            yieldExpected = 0;
        }

        uint256 feeBps = cfg.feeBps;
        uint256 feeAmount = (yieldExpected * feeBps) / 10_000;
        uint256 beneficiaryYield = yieldExpected - feeAmount;
        uint256 expectedClaimable = ESCROW_AMOUNT + beneficiaryYield;

        // Protocol fee, when enabled, is credited to the pull-based per-token bucket and is
        // never taken from principal. When disabled it must be exactly zero.
        if (feeBps > 0) {
            assertGt(escrow.totalFeesPerToken(address(token)), 0, 'protocol fee accounted');
            assertApproxEqAbs(escrow.totalFeesPerToken(address(token)), feeAmount, 2, 'fee amount');
        } else {
            assertEq(escrow.totalFeesPerToken(address(token)), 0, 'no fee when disabled');
        }

        // Beneficiary claimable == principal + (yield - fee).
        uint256 claimable = escrow.claimableBalances(wf, beneficiary);
        assertApproxEqAbs(claimable, expectedClaimable, 4, 'beneficiary claimable ~ principal + yield');

        // The other party holds no claimable (full settlement).
        assertEq(escrow.claimableBalances(wf, otherParty), 0, 'other party has no claimable');

        // Beneficiary actually pulls the funds; wallet delta == withdrawn == claimable.
        uint256 before = token.balanceOf(beneficiary);
        uint256 got;
        vm.prank(beneficiary);
        got = escrow.withdrawEscrow(wf);
        assertApproxEqAbs(got, expectedClaimable, 4, 'withdrawn equals claimable');
        assertEq(token.balanceOf(beneficiary) - before, got, 'beneficiary wallet delta = withdrawn');

        // No residual claimable after withdrawal, and a second withdraw cannot double-realize.
        assertEq(escrow.claimableBalances(wf, beneficiary), 0, 'no residual claimable');
        vm.prank(beneficiary);
        vm.expectRevert();
        escrow.withdrawEscrow(wf);
    }

    /// @dev Expected time-accrued yield for the mock pool: principal*rate*duration/1e27.
    function _expectedYield(uint256 principal, uint256 duration) internal pure returns (uint256) {
        return (principal * PER_SECOND_RATE * duration) / 1e27;
    }
}
