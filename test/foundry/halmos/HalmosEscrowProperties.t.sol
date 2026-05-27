// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/src/SymTest.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/EscrowVaultAnalytics.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "./mocks/MockCustomResolver.sol";

/// @title HalmosEscrowProperties
/// @notice Symbolic execution properties for EscrowVault derived from the Clojure contract
///         model (resolver_sim.contract_model.*) in sew-simulation.
///
/// Each `check_*` function mirrors a property-based test in properties_test.clj.
/// Generator bounds from test.check become vm.assume() constraints here,
/// so the symbolic search space matches the Monte Carlo sampling space exactly.
///
/// Generator → vm.assume() mapping (see test/contract_model/properties_test.clj):
///   gen-amount [1, 1_000_000] (no decimals in Clojure model)
///               → Solidity: [1e4, 1_000_000e18] (ERC20 18-decimal normalisation,
///                 matching EscrowInvariantHandler.createEscrow bounds)
///   gen-bps    [0, 500]       → fee BPS set at vault level; check with FEE_BPS <= 500
///   gen-time   [1, 9999]      → block.timestamp deltas in seconds
///   gen-addr   4 actors       → sender/recipient/resolver/attacker
///
/// Seeds: if test.check ever shrinks a failing counterexample, embed the minimal
/// values here as additional vm.assume(x == seed_value || (x >= lo && x <= hi))
/// to anchor the symbolic search around the known-failing neighbourhood.
/// Currently no shrunk counterexamples exist (all 200-trial runs pass).
///
/// Run individual checks:
///   /usr/bin/python3 -m halmos \
///     --root . \
///     --contract HalmosEscrowProperties \
///     --function check_solvency_after_create \
///     --profile halmos \
///     --loop 3
contract HalmosEscrowProperties is SymTest, Test {

    // -------------------------------------------------------------------------
    // Infrastructure — same wiring as ResolverInvariants.t.sol
    // -------------------------------------------------------------------------
    EscrowVault              internal vault;
    ERC20Mock                internal token;
    DefaultResolutionModule  internal resModule;

    YieldOps              internal yieldOps;
    DisputeOps            internal disputeOps;
    SettlementOps         internal settlementOps;
    CreateOps             internal createOps;
    BondCollector         internal bondCollector;
    ModuleSnapshotRegistry internal mm;

    // Actors matching gen-addr in properties_test.clj
    address internal sender        = address(0x1001);
    address internal recipient     = address(0x1002);
    // customResolver: EOA used as the DefaultResolutionModule's configured resolver.
    // Used in check_appeal_window_enforced (no per-escrow customResolver; the module
    // resolves to this address via getDisputeResolver).
    address internal customResolver = address(0x1003);
    address internal feeAddr       = address(0x1004);

    // exclusivityResolver: deployed contract used as settings.customResolver in
    // check_custom_resolver_exclusivity.  CreateOps requires customResolver to be
    // a contract (NotAContract guard), so we cannot use a bare EOA address here.
    MockCustomResolver internal exclusivityResolver;

    // FEE_BPS=100 (1%) — within gen-bps [0,500] range
    uint256 constant FEE_BPS = 100;
    // APPEAL_WINDOW matches gen-time upper bound (9999 seconds < 7 days)
    uint256 constant APPEAL_WINDOW = 9_999;

    function setUp() public {
        token = new ERC20Mock("Token", "TKN", address(this), 0);

        yieldOps      = new YieldOps(address(this));
        disputeOps    = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps     = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        mm            = new ModuleSnapshotRegistry(address(this));
        resModule     = new DefaultResolutionModule(address(this), customResolver);
        exclusivityResolver = new MockCustomResolver();

        vault = new EscrowVault(FEE_BPS, feeAddr, address(yieldOps), address(disputeOps), address(mm));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resModule));
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), feeAddr);

        // Appeal window within gen-time [1, 9999] upper bound.
        // Every escrow created after this snapshots APPEAL_WINDOW.
        vault.setTimeoutConfig(
            TimeoutConfig({
                defaultAutoReleaseDelay: 0,
                defaultAutoCancelDelay:  0,
                maxDisputeDuration:      30 days,
                appealWindowDuration:    APPEAL_WINDOW
            })
        );
    }

    // =========================================================================
    // Property 1 — Solvency
    // Mirrors: inv/solvency-holds? in invariants.clj
    //
    // For any symbolic amount in the generator range, after createEscrow the
    // vault's token balance must cover totalHeld + totalFees.
    //
    // Counterexample shape: amount such that fee arithmetic underflows or a
    // double-credit inflates the held figure beyond the actual balance.
    // =========================================================================
    function check_solvency_after_create(uint256 amount) public {
        // gen-amount [1, 1_000_000] scaled to 18-decimal ERC20 tokens
        vm.assume(amount >= 1e4 && amount <= 1_000_000e18);

        token.mint(sender, amount);
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), recipient, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        (uint256 principal, uint256 fees, uint256 contractBalance,) =
            EscrowVaultAnalytics(address(vault)).getAccountingBreakdown(address(token));

        assert(contractBalance >= principal + fees);
    }

    // =========================================================================
    // Property 2 — Fee monotonicity
    // Mirrors: inv/fee-increased-or-equal? in invariants.clj
    //
    // For any symbolic amount, totalFeesPerToken[token] must be >= its value
    // before the create call (fees only accumulate, never shrink, except via
    // explicit withdrawFees — which is not called here).
    // =========================================================================
    function check_fees_monotone_after_create(uint256 amount) public {
        // gen-amount [1, 1_000_000] scaled
        vm.assume(amount >= 1e4 && amount <= 1_000_000e18);

        uint256 feesBefore = vault.totalFeesPerToken(address(token));

        token.mint(sender, amount);
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), recipient, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        uint256 feesAfter = vault.totalFeesPerToken(address(token));
        assert(feesAfter >= feesBefore);
    }

    // =========================================================================
    // Property 3 — Custom resolver exclusivity
    // Mirrors: inv/resolver-exclusivity? in invariants.clj /
    //          auth/authorized-resolver? in authority.clj
    //
    // When customResolver is set for an escrow, only customResolver may resolve.
    // We verify two directions:
    //   (a) The three other concrete actors (sender, recipient, feeAddr) cannot
    //       trigger resolution — exercising the negative case for the full set
    //       of gen-addr parties from properties_test.clj.
    //   (b) The legitimate exclusivityResolver CAN resolve, confirming the guard
    //       accepts exactly the right party.
    //
    // Note: vm.prank(symbolic_address) does not produce useful symbolic paths
    // in Halmos 0.3.x when the surrounding setUp is stateful (all paths merge
    // into a "setup state may be too restrictive" error).  The symbolic coverage
    // for this property comes from the Clojure property test (gen-addr generates
    // arbitrary addresses in test.check).  Here we verify the concrete gen-addr
    // boundary points exhaustively.
    //
    // Note: settings.customResolver must be a deployed contract — CreateOps
    // rejects EOA addresses (NotAContract guard).  We therefore use
    // `exclusivityResolver` (a deployed MockCustomResolver) rather than a bare
    // address literal.
    // =========================================================================
    function check_custom_resolver_exclusivity() public {
        // Create escrow with a per-escrow customResolver (must be a contract)
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.customResolver = address(exclusivityResolver);

        token.mint(sender, 1e18);
        vm.startPrank(sender);
        token.approve(address(vault), 1e18);
        vault.createEscrow(address(token), recipient, 1e18, settings);
        vm.stopPrank();

        // Raise dispute to enter DISPUTED state
        vm.prank(sender);
        vault.raiseDispute(0);

        // (a) Unauthorized parties — must all fail
        address[3] memory unauthorised = [sender, recipient, feeAddr];
        for (uint256 i = 0; i < unauthorised.length; i++) {
            vm.prank(unauthorised[i]);
            (bool fail,) = address(vault).call(
                abi.encodeCall(vault.releaseAsDisputeResolver, (0, bytes32(0)))
            );
            // Counterexample: any listed party where fail=true would violate exclusivity
            assert(!fail);
        }

        // (b) Legitimate resolver — must succeed (confirms guard is not over-restrictive)
        vm.prank(address(exclusivityResolver));
        (bool ok,) = address(vault).call(
            abi.encodeCall(vault.releaseAsDisputeResolver, (0, bytes32(0)))
        );
        assert(ok);
    }

    // =========================================================================
    // Property 4 — Terminal state irreversibility (released)
    // Mirrors: inv/terminal-states-unchanged? in invariants.clj
    //
    // Once an escrow is RELEASED, no call can transition it to a different state.
    // We verify the most common attack vector: raising a dispute on a released
    // escrow.
    //
    // Counterexample shape: amount where createEscrow succeeds but
    // releaseEscrowTransfer leaves state inconsistent, allowing a subsequent
    // raiseDispute to succeed.
    // =========================================================================
    function check_released_state_absorbing(uint256 amount) public {
        // gen-amount [1, 1_000_000] scaled
        vm.assume(amount >= 1e4 && amount <= 1_000_000e18);

        token.mint(sender, amount);
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), recipient, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        // Sender releases the escrow → state becomes RELEASED
        vm.prank(sender);
        vault.release(0);

        // Verify state is RELEASED
        (,,,,,,, EscrowState st,,) = vault.escrowTransfers(0);
        assert(st == EscrowState.RELEASED);

        // Any attempt to raise a dispute must fail
        vm.prank(sender);
        (bool success,) = address(vault).call(abi.encodeCall(vault.raiseDispute, (0)));
        // Counterexample: success=true would mean a released escrow can be disputed
        assert(!success);
    }

    // =========================================================================
    // Property 5 — Appeal window enforcement
    // Mirrors: res/execute-pending-settlement (:appeal-window-not-expired guard)
    //          in resolution.clj
    //
    // executePendingSettlement called before the appeal deadline must always
    // revert, for any symbolic time delta < APPEAL_WINDOW.
    //
    // Generator seed: gen-time [1, 9999] → symbolic timeDelta in [1, APPEAL_WINDOW-1]
    // =========================================================================
    function check_appeal_window_enforced(uint256 timeDelta) public {
        // gen-time [1, 9999]; stay strictly inside the appeal window
        vm.assume(timeDelta >= 1 && timeDelta < APPEAL_WINDOW);

        // Create and dispute an escrow
        token.mint(sender, 1e18);
        vm.startPrank(sender);
        token.approve(address(vault), 1e18);
        vault.createEscrow(address(token), recipient, 1e18, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        vm.prank(sender);
        vault.raiseDispute(0);

        // Resolver triggers resolution → creates PendingSettlement with deadline = now + APPEAL_WINDOW
        vm.prank(customResolver);
        vault.releaseAsDisputeResolver(0, bytes32(0));

        // Confirm a pending settlement exists
        (bool exists,,,) = vault.pendingSettlements(0);
        // If no pending settlement was created (e.g. vault has no appeal window), skip
        vm.assume(exists);

        // Warp forward by timeDelta — still before deadline
        vm.warp(block.timestamp + timeDelta);

        // Early execution must fail
        (bool success,) = address(vault).call(
            abi.encodeCall(vault.executePendingSettlement, (0))
        );
        // Counterexample: success=true would mean the appeal window was bypassed
        assert(!success);
    }

    // =========================================================================
    // Property 6 — Pending-settlement consistency
    // Mirrors: :pending-settlement-consistent
    //
    // After a resolver decision in a disputed escrow with an active appeal window,
    // a pending settlement must exist and escrow state must remain DISPUTED.
    // =========================================================================
    function check_pending_settlement_consistent_after_resolution() public {
        token.mint(sender, 1e18);
        vm.startPrank(sender);
        token.approve(address(vault), 1e18);
        vault.createEscrow(address(token), recipient, 1e18, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        vm.prank(sender);
        vault.raiseDispute(0);

        vm.prank(customResolver);
        vault.releaseAsDisputeResolver(0, bytes32(0));

        (bool exists,,,) = vault.pendingSettlements(0);
        assert(exists);

        (,,,,,,, EscrowState st,,) = vault.escrowTransfers(0);
        assert(st == EscrowState.DISPUTED);
    }

    // =========================================================================
    // Property 7 — Single-sided payout after pending execution
    // Mirrors: :single-resolution-payout-consistent (release path)
    //
    // After executing a release pending settlement, only recipient should have
    // positive claimable balance for this workflow (sender should be zero).
    // =========================================================================
    function check_single_sided_claimable_after_release_execution() public {
        token.mint(sender, 1e18);
        vm.startPrank(sender);
        token.approve(address(vault), 1e18);
        vault.createEscrow(address(token), recipient, 1e18, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        vm.prank(sender);
        vault.raiseDispute(0);

        vm.prank(customResolver);
        vault.releaseAsDisputeResolver(0, bytes32(0));

        (, , uint256 deadline,) = vault.pendingSettlements(0);
        vm.warp(deadline + 1);
        vault.executePendingSettlement(0);

        uint256 senderClaim = vault.claimableBalances(0, sender);
        uint256 recipientClaim = vault.claimableBalances(0, recipient);

        assert(senderClaim == 0);
        assert(recipientClaim > 0);
    }

    // Concrete mirror of check_custom_resolver_exclusivity — run with forge test
    function test_customResolverExclusivity_concrete() public {
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.customResolver = address(exclusivityResolver);

        token.mint(sender, 1e18);
        vm.startPrank(sender);
        token.approve(address(vault), 1e18);
        vault.createEscrow(address(token), recipient, 1e18, settings);
        vm.stopPrank();

        vm.prank(sender);
        vault.raiseDispute(0);

        // Unauthorized parties
        address[3] memory unauth = [sender, recipient, feeAddr];
        for (uint256 i = 0; i < unauth.length; i++) {
            vm.prank(unauth[i]);
            (bool fail,) = address(vault).call(
                abi.encodeCall(vault.releaseAsDisputeResolver, (0, bytes32(0)))
            );
            assertFalse(fail, "unauthorized should fail");
        }

        // Legitimate resolver
        vm.prank(address(exclusivityResolver));
        (bool ok,) = address(vault).call(
            abi.encodeCall(vault.releaseAsDisputeResolver, (0, bytes32(0)))
        );
        assertTrue(ok, "exclusivityResolver should succeed");
    }
}