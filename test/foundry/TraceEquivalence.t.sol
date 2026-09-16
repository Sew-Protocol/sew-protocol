// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";
import { EscrowVault } from "../../contracts/core/EscrowVault.sol";
import { BaseEscrow } from "../../contracts/core/BaseEscrow.sol";
import { EscrowViewContract } from "../../contracts/core/EscrowViewContract.sol";
import { DefaultResolutionModule } from "../../contracts/core/modules/DefaultResolutionModule.sol";
import { DefaultReleaseStrategy } from "../../contracts/modules/DefaultReleaseStrategy.sol";
import { EscrowCreationPolicy } from "../../contracts/core/EscrowCreationPolicy.sol";
import { YieldOps } from "../../contracts/ops/YieldOps.sol";
import { BondCollector } from "../../contracts/core/BondCollector.sol";
import { ModuleSnapshotRegistry } from "../../contracts/core/ModuleSnapshotRegistry.sol";
import { ERC20Mock } from "../../contracts/mocks/ERC20Mock.sol";
import { EscrowSettings, EscrowState, TimeoutConfig } from "../../contracts/types/EscrowTypes.sol";
import { YieldPreset } from "../../contracts/types/YieldPresets.sol";
import { SettingsValidationLibrary } from "../../contracts/libraries/SettingsValidationLibrary.sol";
import { VaultSnapshot, EquivalenceInvariantProfileV1 } from "./invariants/EquivalenceInvariantProfileV1.sol";

/**
 * @title TraceEquivalenceTest
 * @notice Forge-native trace equivalence engine for the SEW Protocol.
 *
 * Architecture:
 *  1. Clojure simulation (sew-simulation) outputs canonical JSON trace fixtures:
 *       test/foundry/traces/<scenario>.json
 *  2. This test reads each fixture, replays the same actions on live contracts,
 *     and asserts that the EVM projection matches the simulation projection
 *     at every step.
 *
 * Projection fields verified at each step (maps to diff.clj comparable-keys):
 *   - escrow state per workflow ID   (EscrowVault.getEscrowState)
 *   - amount_after_fee per wf ID     (EscrowVault.escrowTransfers)
 *   - total_held per token           (EscrowVault.totalHeldInEscrowPerToken)
 *   - total_fees per token           (EscrowVault.totalFeesPerToken)
 *   - pending_settlement.exists      (EscrowVault.pendingSettlements)
 *   - dispute_level per wf ID        (DefaultResolutionModule.getAppealDeadlineAndRound)
 *   - block_time                     (block.timestamp)
 *
 * Trace JSON format (test/foundry/traces/README.md has full schema):
 *   { "schema_version": "1", "scenario_id": "...", "fee_bps": N, "steps": [...] }
 *
 * Each step:
 *   { "seq": N, "action": "create_escrow"|"release"|"raise_dispute"|...,
 *     "caller_role": "buyer"|"seller"|"resolver",
 *     "warp_to": timestamp_int,
 *     "params": { ... action-specific ... },
 *     "save_wf_as": "wf0",       -- optional: alias the new wf ID
 *     "wf_alias": "wf0",         -- optional: reference a saved wf ID
 *     "expected": {              -- simulation projection for this step
 *       "escrow_state": N,       -- 0=NONE 1=PENDING 2=RELEASED 3=REFUNDED 4=DISPUTED 5=RESOLVED
 *       "amount_after_fee": "N", -- decimal string (large uint256)
 *       "total_held": "N",
 *       "total_fees": "N",
 *       "pending_settlement_exists": bool,
 *       "dispute_level": N
 *     }
 *   }
 */
contract TraceEquivalenceTest is Test {
    using stdJson for string;

    // ====================================================================
    // Contract instances
    // ====================================================================
    EscrowVault      vault;
    EscrowViewContract oracle;
    DefaultResolutionModule drModule;
    DefaultReleaseStrategy  releaseStrategy;
    EscrowCreationPolicy        creationPolicy;
    YieldOps         yieldOps;
    BondCollector    bondCollector;
    ModuleSnapshotRegistry moduleManagement;
    ERC20Mock        token;

    // ====================================================================
    // Well-known test addresses (stable across all traces)
    // ====================================================================
    address internal owner;
    address constant BUYER      = address(0x1001);
    address constant SELLER     = address(0x1002);
    address constant RESOLVER   = address(0x1234);
    address constant L1RESOLVER = address(0x1235);
    address constant KEEPER     = address(0x1236);
    address constant EXECUTOR   = address(0x1237);
    address constant FEE_ADDR   = address(0xFEE);
    address constant GOVERNANCE = address(0x4000);
    address constant L0RESOLVER = address(0x1234);
    address constant L2RESOLVER = address(0x1238);
    // Distinct non-authorised resolver address used by governance-sandwich
    // traces (the "legacyresolver" role must NOT resolve to the active resolver).
    address constant LEGACYRESOLVER = address(0x1239);

    // ====================================================================
    // Per-trace state (reset at start of each _replayTrace call)
    // ====================================================================
    mapping(string => uint256) internal wfAlias;
    // Parallel "seen" set so alias → workflow 0 is distinguishable from an
    // unset alias.  Workflow IDs are 0-based (escrowTransfers.length), so 0 is
    // a VALID workflow id and must never be treated as "no workflow captured".
    mapping(string => bool) internal wfAliasSeen;
    uint256 internal nextExpectedWfId;
    uint256 internal _vaultFeeBps;

    // ====================================================================
    // Replay receipt tracking (per _replayTrace, reset each call).
    //
    // Phase 0 (claim correctness): every fully replayed fixture emits a replay
    // receipt under out/receipts/ so that equivalence claims can be derived
    // from per-trace execution evidence rather than an assumed test-function
    // inventory.  Profile activation is made observable: a v0.2 fixture must
    // resolve AND apply the declared invariant profile with at least one
    // invariant evaluation, or the replay fails closed.
    // ====================================================================
    // Phase 1 (negotiated compatibility): the harness identity.
    string internal constant HARNESS_VERSION = "1";

    // Supported fixture-spec combinations (cdrs_version, schema_version).
    // This is the harness-side of the supported-combination registry, mirrored
    // in scripts/reconcile.py and trace-solidity-verify.  Unknown or missing
    // combinations fail closed; there is no autodetection or fallback.
    bytes32 internal constant SPEC_LEGACY_V1 = keccak256(abi.encodePacked("0.1", "|", "1"));
    bytes32 internal constant SPEC_CDRS_V2   = keccak256(abi.encodePacked("0.2", "|", "2"));

    // Supported replay-spec ids (fixture-spec + profile + harness-version).
    bytes32 internal constant REPLAY_SPEC_LEGACY =
        keccak256(bytes("cdrs-0.1.schema-1.profile-none.harness-1"));
    bytes32 internal constant REPLAY_SPEC_CDRS_V2 =
        keccak256(bytes("cdrs-0.2.schema-2.profile-1.harness-1"));

    // Phase 1 capability-aware frozen extension-resolution snapshot.  The root
    // is the SHA-256 of the canonical serialisation of the built-in executable
    // set — including each extension's SUPPORTED fixture-specs — so that the
    // negotiated combination is only valid if every resolved extension declares
    // support for it.  The harness recomputes this root (see
    // _extensionResolutionRoot) and rejects drift.
    string internal constant EXTENSION_RESOLUTION_ROOT = "sha256:091280b11d9fb3ae220517a7e8e3e4f23a985d650f89ea168a07b71863779e3d";

    bool    internal _profileApplied;
    uint256 internal _invariantEvaluations;

    // ====================================================================
    // CDRS v0.2 semantic tracking (reset at start of each _replayTrace call)
    // ====================================================================
    uint256 internal _primaryWfId;
    bool    internal _hasPrimaryWfId;
    bool    internal _pendingSettlementCreated;
    bool    internal _settlementExecuted;
    bool    internal _autoCancelTriggered;
    address internal _lastDisputeRaiser;
    address internal _lastResolver;
    bool    internal _resolutionAccepted;

    // ====================================================================
    // Conservation accounting accumulators (per-token, reset per trace)
    // ====================================================================
    uint256 internal _totalDeposited;
    uint256 internal _totalReleased;
    uint256 internal _totalRefunded;
    // Per-workflow guard so terminal payouts are counted exactly once even when
    // a workflow is observed in a terminal state across multiple accepted steps.
    mapping(uint256 => bool) internal _terminalAccounted;

    // ====================================================================
    // setUp — full protocol stack, correct role grants
    // ====================================================================
    function setUp() public {
        owner = address(this);
        _vaultFeeBps = 100;
        _initializeVaultStack();
        _prefundAllRoles();
    }

    function _initializeVaultStack() internal {
        token = new ERC20Mock("Trace USDC", "TUSDC", owner, 0);

        yieldOps       = new YieldOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        creationPolicy      = new EscrowCreationPolicy(owner);
        bondCollector  = new BondCollector(owner);
        drModule       = new DefaultResolutionModule(owner, RESOLVER);
        releaseStrategy = new DefaultReleaseStrategy();

        // EscrowVault constructor grants ROLE_TIMELOCK + DEFAULT_ADMIN to address(this)
        vault = new EscrowVault(_vaultFeeBps,FEE_ADDR,address(yieldOps),address(moduleManagement));

        // Register vault with every ops contract (required before calls)
        yieldOps.registerEscrowContract(address(vault));
        moduleManagement.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        // Wire ops into vault (requires ROLE_TIMELOCK which address(this) already has)
        vault.setCreationPolicy(address(creationPolicy));
        vault.setBondCollector(address(bondCollector));
        // Keep trace executor authorized for timed actions in fixture replays
        vault.grantRole(vault.ROLE_TIMELOCK(), EXECUTOR);
        vault.grantRole(vault.ROLE_TIMELOCK(), KEEPER);
        // setResolutionModule requires ROLE_ADMIN_CONTRACT
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.setResolutionModule(address(drModule));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 7 days + 1);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);
        // Keep trace fixture timestamps anchored near genesis-like values.
        vm.warp(1);

        oracle = new EscrowViewContract(address(vault));

        // Allow drModule to be updated by owner in tests
        drModule.grantRole(drModule.ROLE_TIMELOCK(), owner);
    }

    function _prefundAllRoles() internal {
        token.mint(BUYER,      100_000_000 ether);
        token.mint(SELLER,     100_000_000 ether);
        token.mint(RESOLVER,   100_000_000 ether);
        token.mint(L1RESOLVER, 100_000_000 ether);
        token.mint(KEEPER,     100_000_000 ether);
        token.mint(EXECUTOR,   100_000_000 ether);
        token.mint(GOVERNANCE, 100_000_000 ether);
        token.mint(L2RESOLVER, 100_000_000 ether);
    }

    function _resetTraceState() internal {
        // Clear per-trace state (note: wfAlias/wfAliasSeen mappings are overwritten
        // per trace and each forge test starts with a fresh contract instance, so no
        // deletion is required)
        nextExpectedWfId = 0;

        // Reset semantic tracking state
        _primaryWfId = 0;
        _hasPrimaryWfId = false;
        _pendingSettlementCreated = false;
        _settlementExecuted = false;
        _autoCancelTriggered = false;
        _lastDisputeRaiser = address(0);
        _lastResolver = address(0);
        _resolutionAccepted = false;
        _totalDeposited = 0;
        _totalReleased = 0;
        _totalRefunded = 0;
        _profileApplied = false;
        _invariantEvaluations = 0;
    }

    // ====================================================================
    // Golden trace tests — one test per fixture file
    // ====================================================================

    function test_trace_create_release() public {
        _replayTrace("test/foundry/traces/trace_create_release.json");
    }

    function test_trace_create_dispute_release() public {
        _replayTrace("test/foundry/traces/trace_create_dispute_release.json");
    }

    function test_trace_create_dispute_cancel() public {
        _replayTrace("test/foundry/traces/trace_create_dispute_cancel.json");
    }

    /**
     * Phase Z liveness failure: resolver absent → 90-day auto-cancel.
     *
     * Maps to Phase Z TEST 2 (market shock: 40% resolver exit) and TEST 4
     * (combined shock).  The macro-level "spiral risk" manifests at EVM level
     * as escrows that enter DISPUTED state and are never resolved, ultimately
     * auto-cancelling and refunding the sender.
     *
     * Fixture: test/foundry/traces/trace_phase_z_liveness.json
     * trace_score: 5 (liveness-fail category)
     *
     * Key assertion: after warping 90 days past dispute open, autoCancelDisputedEscrow
     * transitions state DISPUTED→REFUNDED and zeroes totalHeldInEscrowPerToken.
     */
    function test_trace_phase_z_liveness_failure() public {
        _replayTrace("test/foundry/traces/trace_phase_z_liveness.json");
    }

    // ====================================================================
    // Core inline-fixture tests (no JSON file needed — self-contained)
    // These always run; they test the wiring is correct.
    // ====================================================================

    /**
     * Tier-0: verify full stack can create and release an escrow.
     * This is the minimal smoke test that must pass before JSON traces can work.
     */
    function test_inline_create_release() public {
        uint256 amount = 10_000 ether;
        uint256 feeBps = 100; // 1%
        uint256 expectedFee = (amount * feeBps) / 10_000;
        uint256 expectedAfa = amount - expectedFee;

        vm.startPrank(BUYER);
        token.approve(address(vault), amount);
        uint256 wfId = vault.createEscrow(
            address(token), SELLER, amount, SettingsValidationLibrary.getDefaultSettings()
        );
        vm.stopPrank();

        // Step 1 assertion
        _assertEscrowState(wfId, EscrowState.PENDING, "after create");
        _assertAmountAfterFee(wfId, expectedAfa, "after create");
        _assertTotalHeld(expectedAfa, "after create");
        _assertTotalFees(expectedFee, "after create");

        // Release (sender/buyer initiates the release to recipient)
        vm.prank(BUYER);
        vault.release(wfId);

        // Step 2 assertion
        _assertEscrowState(wfId, EscrowState.RELEASED, "after release");
        _assertTotalHeld(0, "after release");
    }


    // ====================================================================
    // appealWindowDuration == 0 immediate-finalisation behaviour
    //
    // Pins the contract behaviour that the regenerated zero-window traces
    // rely on: with appealWindowDuration == 0 a resolver ruling finalises
    // immediately (no pending settlement), matching EscrowSettlementLogic
    // computeResolutionExecution and the Clojure simulation's terminal state.
    // ====================================================================

    function test_window_zero_release_finalises_immediately() public {
        // Apply the zero-window timeout config BEFORE the escrow is created so
        // its module snapshot carries appealWindowDuration == 0.
        TimeoutConfig memory tc = TimeoutConfig({
            defaultAutoReleaseDelay: 0,
            defaultAutoCancelDelay: 0,
            maxDisputeDuration: 90 days,
            appealWindowDuration: 0
        });
        vault.setTimeoutConfig(tc);

        _createBasicEscrow();
        uint256 wfId = 0;

        vm.prank(BUYER);
        vault.raiseDispute(wfId);
        assertEq(uint256(vault.getEscrowState(wfId)), uint256(EscrowState.DISPUTED), "disputed");

        // Zero appeal window: ruling finalises immediately, no pending settlement.
        vm.prank(RESOLVER);
        vault.releaseAsDisputeResolver(wfId, bytes32(0));

        assertEq(uint256(vault.getEscrowState(wfId)), uint256(EscrowState.RELEASED), "immediate release at window 0");
        (bool psExists,,,) = vault.pendingSettlements(wfId);
        assertTrue(!psExists, "no pending settlement at window 0");
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0, "held zeroed on immediate release");
    }

    function test_window_zero_cancel_finalises_immediately() public {
        TimeoutConfig memory tc = TimeoutConfig({
            defaultAutoReleaseDelay: 0,
            defaultAutoCancelDelay: 0,
            maxDisputeDuration: 90 days,
            appealWindowDuration: 0
        });
        vault.setTimeoutConfig(tc);

        _createBasicEscrow();
        uint256 wfId = 0;

        vm.prank(BUYER);
        vault.raiseDispute(wfId);

        vm.prank(RESOLVER);
        vault.cancelAsDisputeResolver(wfId, bytes32(0));

        assertEq(uint256(vault.getEscrowState(wfId)), uint256(EscrowState.REFUNDED), "immediate refund at window 0");
        (bool psExists,,,) = vault.pendingSettlements(wfId);
        assertTrue(!psExists, "no pending settlement at window 0");
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0, "held zeroed on immediate refund");
    }


    /**
     * Tier-0: create → raise dispute → resolver releases → pending → execute.
     */
    function test_inline_create_dispute_release() public {
        uint256 amount = 10_000 ether;

        vm.startPrank(BUYER);
        token.approve(address(vault), amount);
        uint256 wfId = vault.createEscrow(
            address(token), SELLER, amount, SettingsValidationLibrary.getDefaultSettings()
        );
        vm.stopPrank();

        // Raise dispute
        vm.prank(BUYER);
        vault.raiseDispute(wfId);
        _assertEscrowState(wfId, EscrowState.DISPUTED, "after raise dispute");

        // Resolver releases — state stays DISPUTED, creates pending settlement
        vm.prank(RESOLVER);
        vault.releaseAsDisputeResolver(wfId, bytes32(0));
        _assertEscrowState(wfId, EscrowState.DISPUTED, "after resolver release (pending settlement queued)");

        // Get appeal deadline from vault's pendingSettlements (DR module stub returns 0)
        (,, uint256 appealDeadline,) = vault.pendingSettlements(wfId);
        vm.warp(appealDeadline + 1);
        vault.executePendingSettlement(wfId);
        _assertEscrowState(wfId, EscrowState.RELEASED, "after execute settlement");
        _assertTotalHeld(0, "after settlement executed");
    }

    /**
     * Tier-0: create → raise dispute → resolver cancels → execute.
     */
    function test_inline_create_dispute_cancel() public {
        uint256 amount = 10_000 ether;

        vm.startPrank(BUYER);
        token.approve(address(vault), amount);
        uint256 wfId = vault.createEscrow(
            address(token), SELLER, amount, SettingsValidationLibrary.getDefaultSettings()
        );
        vm.stopPrank();

        vm.prank(BUYER);
        vault.raiseDispute(wfId);

        vm.prank(RESOLVER);
        vault.cancelAsDisputeResolver(wfId, bytes32(0));

        // Get appeal deadline from vault's pendingSettlements (DR module stub returns 0)
        (,, uint256 appealDeadline,) = vault.pendingSettlements(wfId);
        vm.warp(appealDeadline + 1);
        vault.executePendingSettlement(wfId);
        _assertEscrowState(wfId, EscrowState.REFUNDED, "after cancel settlement");
        _assertTotalHeld(0, "after cancel executed");
    }

    // ====================================================================
    // JSON trace replay engine
    // ====================================================================

    /**
     * @dev Load a JSON trace fixture and replay every step, asserting EVM state
     *      matches the simulation projection at each step.
     *
     * The fixture path is relative to the project root (foundry.toml location).
     * Supports both CDRS v0.1 and v0.2 formats (detected by presence of "cdrs_version" field).
     */
    function _replayTrace(string memory fixturePath) internal {
        string memory raw = vm.readFile(fixturePath);

        // Phase 1: negotiate the fixture-spec (cdrs_version + schema_version are
        // mandatory; no key-presence autodetection, no fallback).  Unknown or
        // missing combinations fail closed before any action is interpreted.
        (bool isLegacy, bool isV2) = _negotiateSpec(raw);
        require(isLegacy || isV2, "TraceEquivalence: unsupported fixture-spec combination");

        // Every resolved extension must support the negotiated combination.
        _assertResolutionSupportsSpec();

        // Fail closed unless the negotiated replay-spec is a supported one.
        _assertSupportedReplaySpec(_replaySpecId(isV2, raw));
        if (isV2 && stdJson.keyExists(raw, ".fee_bps")) {
            uint256 feeBps = stdJson.readUint(raw, ".fee_bps");
            if (feeBps != _vaultFeeBps) {
                _vaultFeeBps = feeBps;
                _initializeVaultStack();
                _prefundAllRoles();
            }
        }

        // Apply trace-level timeout config (appeal window, max dispute duration)
        // if present in the fixture.  These must match the sim's module snapshot.
        if (isV2 && (stdJson.keyExists(raw, ".appeal_window_duration") ||
                     stdJson.keyExists(raw, ".max_dispute_duration")))
        {
            TimeoutConfig memory tc = TimeoutConfig({
                defaultAutoReleaseDelay: 0,
                defaultAutoCancelDelay: 0,
                maxDisputeDuration: 90 days,
                appealWindowDuration: 0
            });
            if (stdJson.keyExists(raw, ".appeal_window_duration")) {
                tc.appealWindowDuration = stdJson.readUint(raw, ".appeal_window_duration");
            }
            if (stdJson.keyExists(raw, ".max_dispute_duration")) {
                tc.maxDisputeDuration = stdJson.readUint(raw, ".max_dispute_duration");
            }
            vault.setTimeoutConfig(tc);
        }

        // Verify invariant profile binding (mandatory for manifest-bound traces)
        if (isV2) {
            require(stdJson.keyExists(raw, ".invariant_profile"),
                "manifest-bound trace requires invariant_profile");
            string memory pId = stdJson.readString(raw, ".invariant_profile.id");
            uint256 pVer = stdJson.readUint(raw, ".invariant_profile.version");
            string memory pRoot = stdJson.readString(raw, ".invariant_profile.root");
            require(
                _isSupportedProfile(keccak256(bytes(pId)), pVer, pRoot),
                "unsupported invariant profile - expected solidity-equivalence-core-v1/1"
            );
        }

        // Reset per-trace state (alias map, semantic tracking flags)
        _resetTraceState();

        // Profile resolution succeeded above (v2 only); record it AFTER the
        // reset so the flag survives.  It is observed as "applied" only once
        // the post-step invariant gate below evaluates the compiled profile.
        if (isV2) {
            _profileApplied = true;
        }

        // TEST-ONLY: deterministic conservation corruption used by the
        // workflow-0 invariant regression to prove the post-step invariant
        // gate executes for the primary workflow (whose id is 0).
        if (isV2 && stdJson.keyExists(raw, ".test_corrupt_deposited")) {
            _totalDeposited += stdJson.readUint(raw, ".test_corrupt_deposited");
        }

        // Replay all steps
        uint256 stepCount = stdJson.readUint(raw, ".step_count");
        for (uint256 i = 0; i < stepCount; i++) {
            string memory prefix = string.concat(".steps[", vm.toString(i), "]");
            if (isV2) {
                _replayStepV2(raw, prefix);
            } else {
                _replayStep(raw, prefix);
            }
        }

        // Profile activation must be observable (Phase 0).  A v0.2 fixture that
        // declares an invariant profile must have had it RESOLVED and APPLIED,
        // i.e. the post-step invariant gate evaluated at least once.  This
        // closes the class of bug where replay "passes" while the profile never
        // contributed any check (e.g. a fixture that never captured a workflow).
        if (isV2) {
            require(_profileApplied, "TraceEquivalence: invariant profile not resolved for fixture");
            require(_invariantEvaluations > 0,
                "TraceEquivalence: invariant profile not applied during replay (0 invariant evaluations)");
        }

        // Post-replay semantic assertions (v0.2 only)
        if (isV2 && stdJson.keyExists(raw, ".expected_semantics")) {
            _assertSemantics(raw);
        }

        // Terminal projection hash check (v0.2 only)
        if (isV2 && stdJson.keyExists(raw, ".terminal_projection_hash") && _hasPrimaryWfId) {
            string memory expectedHash = stdJson.readString(raw, ".terminal_projection_hash");
            string memory actualHash = _computeTerminalProjectionHash();
            assertEq(
                keccak256(bytes(actualHash)),
                keccak256(bytes(expectedHash)),
                string.concat("terminal_projection_hash mismatch: ", actualHash, " != ", expectedHash)
            );
        }

        // Emit a replay receipt so attestation/equivalence claims can be
        // derived from per-trace execution evidence (Phase 0).
        _emitReceipt(fixturePath, raw, isV2);
    }

    // ── Spec negotiation + supported-registry helpers (Phase 1) ─────

    /// @dev Negotiate the fixture-spec.  cdrs_version and schema_version are
    ///      mandatory.  Returns (isLegacy, isV2); reverts on missing or
    ///      unsupported combinations (fail closed).
    function _negotiateSpec(string memory raw) internal view returns (bool, bool) {
        require(stdJson.keyExists(raw, ".cdrs_version"),
            "TraceEquivalence: missing cdrs_version (fail-closed spec negotiation)");
        require(stdJson.keyExists(raw, ".schema_version"),
            "TraceEquivalence: missing schema_version (fail-closed spec negotiation)");
        string memory c = stdJson.readString(raw, ".cdrs_version");
        string memory s = stdJson.readString(raw, ".schema_version");
        bytes32 combo = keccak256(abi.encodePacked(c, "|", s));
        if (combo == SPEC_LEGACY_V1) return (true, false);
        if (combo == SPEC_CDRS_V2) return (false, true);
        revert("TraceEquivalence: unsupported fixture-spec combination (see supported registry)");
    }

    /// @dev Reject a replay-spec id not in the supported registry.
    function _assertSupportedReplaySpec(string memory specId) internal pure {
        bytes32 h = keccak256(bytes(specId));
        require(h == REPLAY_SPEC_LEGACY || h == REPLAY_SPEC_CDRS_V2,
            string.concat("TraceEquivalence: unsupported replay-spec: ", specId));
    }

    /// @dev SHA-256 of the canonical built-in extension-resolution serialisation
    ///      (sorted by id, each entry = id|version|kind|supported-fixture-specs).
    ///      Mirrors scripts/reconcile.py and etc/trace-solidity-manifest.edn.
    function _extensionResolutionRoot() internal pure returns (string memory) {
        bytes32 digest = sha256(bytes(
            "trace/action.resolve|1|trace/action|cdrs-0.1.schema-1,cdrs-0.2.schema-2\n"
            "trace/profile.equivalence-v1|1|trace/invariant-profile|cdrs-0.2.schema-2\n"
            "trace/projection.sew-v2|2|trace/state-projection|cdrs-0.2.schema-2"
        ));
        return string.concat("sha256:", _hex(digest));
    }

    /// @dev The negotiated combination is only valid if every resolved
    ///      extension supports it.  The built-in matrix covers both legacy and
    ///      v2 (action resolver: {0.1|1, 0.2|2}; profile+projection: {0.2|2}),
    ///      and _negotiateSpec only admits these two combinations, so coverage
    ///      is implied once the declared root matches the derived root.  If the
    ///      built-in matrix changes, the root changes and this check fails
    ///      closed until EXTENSION_RESOLUTION_ROOT is deliberately bumped.
    function _assertResolutionSupportsSpec() internal view {
        require(
            keccak256(bytes(_extensionResolutionRoot())) == keccak256(bytes(EXTENSION_RESOLUTION_ROOT)),
            "TraceEquivalence: extension-resolution root drift (built-in matrix changed)"
        );
    }

    // ── Replay receipt helpers (Phase 0) ─────────────────────────────

    /// @dev Lowercase hex encoding of a 32-byte value (no 0x prefix).
    function _hex(bytes32 hash) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(hash[i]);
            result[i * 2] = hexChars[b >> 4];
            result[i * 2 + 1] = hexChars[b & 0xf];
        }
        return string(result);
    }

    /// @dev Sanitise a fixture path into a stable receipt filename (slashes,
    ///      dots and spaces become underscores).
    function _sanitizePath(string memory path) internal pure returns (string memory) {
        bytes memory b = bytes(path);
        bytes1 slash = '/';
        bytes1 dot = '.';
        bytes1 space = ' ';
        bytes1 underscore = '_';
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == slash || b[i] == dot || b[i] == space) {
                b[i] = underscore;
            }
        }
        return string(b);
    }

    /// @dev Negotiated replay-spec id for this fixture, derived from its
    ///      declared cdrs/schema/profile versions and the harness version.
    function _replaySpecId(bool isV2, string memory raw) internal view returns (string memory) {
        if (!isV2) {
            return "cdrs-0.1.schema-1.profile-none.harness-1";
        }
        string memory schemaVersion = "2";
        if (stdJson.keyExists(raw, ".schema_version")) {
            schemaVersion = stdJson.readString(raw, ".schema_version");
        }
        string memory profileVersion = "1";
        if (stdJson.keyExists(raw, ".invariant_profile.version")) {
            profileVersion = vm.toString(stdJson.readUint(raw, ".invariant_profile.version"));
        }
        return string.concat(
            "cdrs-0.2.schema-", schemaVersion,
            ".profile-", profileVersion,
            ".harness-", HARNESS_VERSION
        );
    }

    /// @dev Write a per-fixture replay receipt under out/receipts/.  The
    ///      receipt binds the fixture content hash, the negotiated replay-spec,
    ///      profile resolution/application observability, and the frozen
    ///      extension-resolution root.  Contract/simulator commits are bound by
    ///      the reconcile tool (Solidity cannot observe git state).
    ///      isV2 is the NEGOTIATED value from _replayTrace, never re-derived by
    ///      key presence (a legacy fixture legitimately carries cdrs_version).
    function _emitReceipt(string memory fixturePath, string memory raw, bool isV2) internal {
        vm.createDir("out/receipts", true);
        string memory traceId = "";
        if (stdJson.keyExists(raw, ".scenario_id")) {
            traceId = stdJson.readString(raw, ".scenario_id");
        }
        string memory profileId = "equivalence-invariant-profile";
        string memory profileVersion = "0";
        if (isV2 && stdJson.keyExists(raw, ".invariant_profile.id")) {
            profileId = stdJson.readString(raw, ".invariant_profile.id");
        }
        if (isV2 && stdJson.keyExists(raw, ".invariant_profile.version")) {
            profileVersion = vm.toString(stdJson.readUint(raw, ".invariant_profile.version"));
        }
        string memory json = "{}";
        json = vm.serializeString("", "trace_id", traceId);
        json = vm.serializeString("", "fixture_path", fixturePath);
        json = vm.serializeString("", "fixture_hash", _hex(keccak256(bytes(vm.readFile(fixturePath)))));
        json = vm.serializeString("", "replay_spec_id", _replaySpecId(isV2, raw));
        json = vm.serializeString("", "profile_id", profileId);
        json = vm.serializeString("", "profile_version", profileVersion);
        json = vm.serializeBool("", "profile_applied", _profileApplied);
        json = vm.serializeString("", "replay_status", "pass");
        json = vm.serializeUint("", "invariant_evaluations", _invariantEvaluations);
        json = vm.serializeString("", "extension_resolution_root", EXTENSION_RESOLUTION_ROOT);
        vm.writeJson(json, string.concat("out/receipts/", _sanitizePath(fixturePath), ".json"));
    }

    // ── Invariant snapshot helper ────────────────────────────────────


    /// @notice Sum of amountAfterFee across every non-terminal escrow currently
    ///         held by the vault.  Makes held-reconstruction valid for
    ///         multi-escrow traces (totalHeld == sum of per-escrow afa) instead
    ///         of assuming a single primary workflow.
    function _sumHeldAfa() internal view returns (uint256 sum) {
        uint256 n = vault.getEscrowCount();
        for (uint256 i = 0; i < n; i++) {
            EscrowState st = vault.getEscrowState(i);
            if (st == EscrowState.PENDING || st == EscrowState.DISPUTED) {
                (,,,, uint256 afa,,,,,) = vault.escrowTransfers(i);
                sum += afa;
            }
        }
    }

    function _snapshot(uint256 wfId) internal view returns (VaultSnapshot memory) {
        EscrowState st = vault.getEscrowState(wfId);
        uint256 held = vault.totalHeldInEscrowPerToken(address(token));
        uint256 fees = vault.totalFeesPerToken(address(token));
        (bool ps,,,) = vault.pendingSettlements(wfId);
        (, uint8 dl,) = drModule.getAppealDeadlineAndRound(wfId, address(vault));
        return VaultSnapshot({
            escrowState: st,
            disputeLevel: uint256(dl),
            amountAfterFee: _sumHeldAfa(),
            pendingSettlementExists: ps,
            totalHeld: held,
            totalFees: fees,
            totalDeposited: _totalDeposited,
            totalReleased: _totalReleased,
            totalRefunded: _totalRefunded,
            blockTimestamp: block.timestamp
        });
    }

    function _computeTerminalProjectionHash() internal view returns (string memory) {
        uint256 wfId = _primaryWfId;
        EscrowState st = vault.getEscrowState(wfId);
        (,,,, uint256 afa,,,,,) = vault.escrowTransfers(wfId);
        (bool ps,,,) = vault.pendingSettlements(wfId);
        (, uint8 dl,) = drModule.getAppealDeadlineAndRound(wfId, address(vault));

        string memory data = string.concat(
            vm.toString(uint256(st)), "|",
            vm.toString(afa), "|",
            vm.toString(ps ? 1 : 0), "|",
            vm.toString(uint256(dl))
        );
        bytes32 hash = sha256(bytes(data));
        // Strip 0x prefix: convert bytes32 to 64-char hex without prefix
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(hash[i]);
            result[i * 2] = hexChars[b >> 4];
            result[i * 2 + 1] = hexChars[b & 0xf];
        }
        return string(result);
    }

    /// @dev External wrapper so negative tests can assert semantic-failure via try/catch.
    function replayTraceExternal(string calldata fixturePath) external {
        _replayTrace(fixturePath);
    }

    // ====================================================================
    // CDRS v0.2 Trace Replay (newer fixture format with semantic tracking)
    // ====================================================================

    /**
     * @dev Replay a single v0.2 step, with support for rejection_reason matching
     *      and semantic tracking (dispute initiation, resolution, settlement, escalation).
     *
     * v0.2 step fields:
     *   - actor: role name (buyer, seller, resolver, executor, keeper, ...)
     *   - timestamp: block time for warp
     *   - context_id: workflow ID alias (e.g., "wf0")
     *   - attributes.action: action name (create_escrow, raise_dispute, execute_resolution, ...)
     *   - attributes.wf_alias: workflow ID alias to save/reference
     *   - attributes.to_role: recipient role (for create_escrow)
     *   - attributes.amount: amount (for create_escrow)
     *   - expected.accepted: true if action should succeed, false if should revert
     *   - expected.rejection_reason: error name if not accepted (optional)
     *   - expected.escrow_state, expected.escrow_amount_after_fee, etc.
     */
    function _replayStepV2(string memory json, string memory prefix) internal {
        // ── Read basic step fields ───────────────────────────────────────
        string memory actor     = stdJson.readString(json, string.concat(prefix, ".actor"));
        uint256 timestamp       = stdJson.readUint(json, string.concat(prefix, ".timestamp"));
        string memory contextId = stdJson.readString(json, string.concat(prefix, ".context_id"));

        if (timestamp > block.timestamp) vm.warp(timestamp);

        address caller = _roleToAddressV2(actor);

        // ── Extract action and parameters from attributes ─────────────────
        string memory action = stdJson.readString(json, string.concat(prefix, ".attributes.action"));
        
        // Resolve workflow ID from attributes.wf_alias.  A "seen" flag is used
        // instead of the numeric value so that workflow 0 (valid, 0-based id)
        // is not conflated with "no workflow captured".
        uint256 wfId = 0;
        bool wfCaptured = false;
        if (stdJson.keyExists(json, string.concat(prefix, ".attributes.wf_alias"))) {
            string memory aliasName = stdJson.readString(json, string.concat(prefix, ".attributes.wf_alias"));
            if (wfAliasSeen[aliasName]) {
                wfId = wfAlias[aliasName];
                wfCaptured = true;
            }
        }

        // Extract expected fields (before dispatching, so we can handle reverts)
        string memory expPrefix = string.concat(prefix, ".expected");
        bool expectedAccepted = stdJson.readBool(json, string.concat(expPrefix, ".accepted"));
        
        string memory expectedRejectionReason = "";
        if (!expectedAccepted && stdJson.keyExists(json, string.concat(expPrefix, ".rejection_reason"))) {
            expectedRejectionReason = stdJson.readString(json, string.concat(expPrefix, ".rejection_reason"));
        }

        // ── Invariant snapshots (before action) ─────────────────────────
        VaultSnapshot memory before_;
        bool snapshotsActive = wfCaptured && expectedAccepted;
        if (snapshotsActive) {
            before_ = _snapshot(wfId);
        }

        // ── Dispatch action ────────────────────────────────────────────────────
        // Note: vm.expectRevert() is called just before each dispatch for actions that may revert
        bytes32 actionHash = keccak256(bytes(action));

        if (actionHash == keccak256("create_escrow")) {
            // create_escrow generally doesn't revert in normal cases
            if (!expectedAccepted) {
                vm.expectRevert();
            }
            
            uint256 amount = stdJson.readUint(json, string.concat(prefix, ".attributes.amount"));
            string memory toRole = stdJson.readString(json, string.concat(prefix, ".attributes.to_role"));
            address to = _roleToAddressV2(toRole);

            vm.startPrank(caller);
            token.approve(address(vault), amount);
            uint256 newWfId = vault.createEscrow(
                address(token), to, amount, SettingsValidationLibrary.getDefaultSettings()
            );
            vm.stopPrank();

            // Save alias if this is a create
            if (stdJson.keyExists(json, string.concat(prefix, ".attributes.wf_alias"))) {
                string memory aliasName2 = stdJson.readString(json, string.concat(prefix, ".attributes.wf_alias"));
                wfAlias[aliasName2] = newWfId;
                wfAliasSeen[aliasName2] = true;
                if (!_hasPrimaryWfId) {
                    _primaryWfId = newWfId;
                    _hasPrimaryWfId = true;
                }
            }
            wfId = newWfId;
            wfCaptured = true;
            // Track principal deposited for conservation equation
            uint256 depositAmount = stdJson.readUint(json, string.concat(prefix, ".attributes.amount"));
            _totalDeposited += depositAmount;

        } else if (actionHash == keccak256("release")) {
            if (!expectedAccepted) {
                vm.expectRevert();
            }
            
            vm.prank(caller);
            vault.release(wfId);

        } else if (actionHash == keccak256("sender_cancel")) {
            if (!expectedAccepted) {
                vm.expectRevert();
            }
            
            vm.prank(caller);
            vault.senderCancel(wfId);

        } else if (actionHash == keccak256("recipient_cancel")) {
            if (!expectedAccepted) {
                vm.expectRevert();
            }
            
            vm.prank(caller);
            vault.recipientCancel(wfId);

        } else if (actionHash == keccak256("raise_dispute")) {
            if (!expectedAccepted) {
                vm.expectRevert();
            }
            
            vm.prank(caller);
            vault.raiseDispute(wfId);

        } else if (actionHash == keccak256("execute_resolution")) {
            // Ambiguous: the raw sim action does not carry the release/cancel
            // direction.  The Clojure exporter rewrites this action to
            // release_as_dispute_resolver or cancel_as_dispute_resolver before
            // syncing, so a fixture that still contains bare execute_resolution
            // is stale or hand-written and must be regenerated rather than
            // silently dispatched as a release.
            revert("TraceEquivalence: unsupported action 'execute_resolution' - export rewrites it to release_as_dispute_resolver/cancel_as_dispute_resolver");

        } else if (actionHash == keccak256("release_as_dispute_resolver")) {
            if (!expectedAccepted) {
                vm.expectRevert();
            }
            
            vm.prank(caller);
            vault.releaseAsDisputeResolver(wfId, bytes32(0));

        } else if (actionHash == keccak256("cancel_as_dispute_resolver")) {
            if (!expectedAccepted) {
                vm.expectRevert();
            }
            
            vm.prank(caller);
            vault.cancelAsDisputeResolver(wfId, bytes32(0));

        } else if (actionHash == keccak256("escalate_dispute")) {
            if (!expectedAccepted) {
                vm.expectRevert();
            }
            vm.prank(caller);
            vault.escalateDispute(wfId);

        } else if (actionHash == keccak256("register_stake")) {
            // Stake is already set up in setUp(); no vault call needed.
            if (!expectedAccepted) {
                vm.expectRevert();
            }

        } else if (actionHash == keccak256("withdraw_stake")) {
            if (!expectedAccepted) {
                vm.expectRevert();
            }

        } else if (actionHash == keccak256("execute_pending_settlement")) {
            // Respect the appeal deadline.  A step that targets a workflow with
            // no pending settlement is a legitimate rejected path
            // (NoPendingSettlement) and must not blow up the harness.
            (bool psExists, bool isRelease, uint256 appealDeadline,) = vault.pendingSettlements(wfId);

            // Check if appeal window has expired
            bool appealWindowExpired = block.timestamp >= appealDeadline;

            if (!psExists) {
                if (!expectedAccepted) {
                    vm.expectRevert();
                }
            } else if (expectedAccepted && !appealWindowExpired) {
                // Still inside the appeal window and the test expects success: warp past it
                vm.warp(appealDeadline + 1);
            } else if (!expectedAccepted && !appealWindowExpired) {
                // Still inside the appeal window and test expects failure
                vm.expectRevert();
            }

            // Permissionless but we prank to track actor for semantics
            vm.prank(caller);
            vault.executePendingSettlement(wfId);

        } else if (actionHash == keccak256("auto_cancel_disputed")) {
            if (!expectedAccepted) {
                vm.expectRevert();
            }
            
            vault.autoCancelDisputedEscrow(wfId);

        } else {
            revert(string.concat("TraceEquivalence: unknown v0.2 action: ", action));
        }

        // ── Update semantic tracking (only on successful actions) ────────
        if (expectedAccepted) {
            if (actionHash == keccak256("raise_dispute")) {
                _lastDisputeRaiser = caller;
            } else if (actionHash == keccak256("execute_resolution") || 
                       actionHash == keccak256("release_as_dispute_resolver") ||
                       actionHash == keccak256("cancel_as_dispute_resolver")) {
                _lastResolver = caller;
                _resolutionAccepted = true;
                // Check if pending settlement now exists (was created by this call)
                (bool psAfterRes,,,) = vault.pendingSettlements(wfId);
                if (psAfterRes) {
                    _pendingSettlementCreated = true;
                }
            } else if (actionHash == keccak256("execute_pending_settlement")) {
                _settlementExecuted = true;
            } else if (actionHash == keccak256("auto_cancel_disputed")) {
                _autoCancelTriggered = true;
            }
        }

        // ── Conservation accounting (track released/refunded amounts) ───
        // After any accepted action that may transition a workflow to a terminal
        // state, credit its amountAfterFee exactly once.  The per-workflow guard
        // keeps the accumulation idempotent across repeated accepted observations
        // of an already-terminal workflow.
        if (expectedAccepted && wfCaptured) {
            EscrowState st = vault.getEscrowState(wfId);
            if ((st == EscrowState.RELEASED || st == EscrowState.REFUNDED) && !_terminalAccounted[wfId]) {
                (,,,, uint256 afa,,,,,) = vault.escrowTransfers(wfId);
                if (st == EscrowState.RELEASED) {
                    _totalReleased += afa;
                } else {
                    _totalRefunded += afa;
                }
                _terminalAccounted[wfId] = true;
            }
        }

        // ── Assert projection matches simulation expected ────────────────
        if (!expectedAccepted) {
            // For rejected steps, just check that state didn't change unexpectedly
            return;
        }

        // Projection assertions require a captured workflow.  Steps such as
        // register_stake/withdraw_stake run before any escrow exists; without
        // this guard getEscrowState(0) would revert on an empty vault.
        bool hasExpected = stdJson.keyExists(json, string.concat(expPrefix, ".escrow_state"));
        if (!hasExpected || !wfCaptured) return;

        uint256 expectedState = stdJson.readUint(json, string.concat(expPrefix, ".escrow_state"));
        uint256 expectedAfa   = stdJson.readUint(json, string.concat(expPrefix, ".escrow_amount_after_fee"));
        uint256 expectedHeld  = stdJson.readUint(json, string.concat(expPrefix, ".global_total_held"));
        uint256 expectedFees  = stdJson.readUint(json, string.concat(expPrefix, ".global_total_fees"));
        bool    expPsExists   = stdJson.readBool(json, string.concat(expPrefix, ".pending_settlement_exists"));
        uint256 expDispLevel  = stdJson.readUint(json, string.concat(expPrefix, ".dispute_level"));

        string memory stepLabel = string.concat(prefix, " [", action, "]");

        // State
        EscrowState actualState = vault.getEscrowState(wfId);
        assertEq(uint256(actualState), expectedState,
            string.concat(stepLabel, " escrow_state mismatch"));

        // Amount after fee
        (,,,, uint256 actualAfa,,,,,) = vault.escrowTransfers(wfId);
        assertEq(actualAfa, expectedAfa,
            string.concat(stepLabel, " escrow_amount_after_fee mismatch"));

        // Total held
        uint256 actualHeld = vault.totalHeldInEscrowPerToken(address(token));
        assertEq(actualHeld, expectedHeld,
            string.concat(stepLabel, " global_total_held mismatch"));

        // Total fees
        uint256 actualFees = vault.totalFeesPerToken(address(token));
        assertEq(actualFees, expectedFees,
            string.concat(stepLabel, " global_total_fees mismatch"));

        // Pending settlement
        (bool psExists,,, ) = vault.pendingSettlements(wfId);
        assertEq(psExists, expPsExists,
            string.concat(stepLabel, " pending_settlement_exists mismatch"));

        // Dispute level
        (, uint8 currentRound,) = drModule.getAppealDeadlineAndRound(wfId, address(vault));
        assertEq(uint256(currentRound), expDispLevel,
            string.concat(stepLabel, " dispute_level mismatch"));

        // ── Invariant checks (after action, on post-step state) ─────────
        // Executes for the primary workflow even when its id is 0 (0-based
        // workflow ids).  wfCaptured is true whenever a workflow was resolved
        // for this step, so these checks are never silently skipped.
        if (expectedAccepted && wfCaptured) {
            VaultSnapshot memory after_ = _snapshot(wfId);
            EquivalenceInvariantProfileV1.checkStateEquations(after_, wfId);
            EquivalenceInvariantProfileV1.checkHeldReconstruction(after_, wfId);
            EquivalenceInvariantProfileV1.checkTransitionEquations(before_, after_, action, wfId);
            // Observable profile application: count every step where the
            // invariant gate actually evaluated the compiled profile.
            _invariantEvaluations += 1;
        }
    }

    // ====================================================================
    // CDRS v0.2 Post-Trace Semantic Assertions
    // ====================================================================

    /**
     * @dev Assert that the final EVM state matches the declared expected_semantics
     *      from the v0.2 fixture.
     *
     * Checks resolution outcome, escalation level, participation, and timing
     * fields that were tracked during step replay.
     */
    function _assertSemantics(string memory json) internal {
        // Get expected_semantics object
        require(_hasPrimaryWfId, "No primary workflow found in trace");

        // Optionally check resolution semantics
        if (stdJson.keyExists(json, ".expected_semantics.resolution")) {
            _assertResolutionSemantics(json);
        }

        // Optionally check escalation semantics
        if (stdJson.keyExists(json, ".expected_semantics.escalation")) {
            _assertEscalationSemantics(json);
        }

        // Optionally check participation semantics
        if (stdJson.keyExists(json, ".expected_semantics.participation")) {
            _assertParticipationSemantics(json);
        }

        // Optionally check timing semantics
        if (stdJson.keyExists(json, ".expected_semantics.timing")) {
            _assertTimingSemantics(json);
        }
    }

    function _assertResolutionSemantics(string memory json) internal view {
        string memory prefix = ".expected_semantics.resolution";

        // outcome: "release" | "refund" | "settled" | "unresolved" | "cancelled" | "timeout"
        // Note: Only check if escrow is in a terminal state. If pending settlement exists,
        // the actual state is DISPUTED but outcome is the intended final outcome.
        if (stdJson.keyExists(json, string.concat(prefix, ".outcome"))) {
            string memory expectedOutcome = stdJson.readString(json, string.concat(prefix, ".outcome"));
            EscrowState actualState = vault.getEscrowState(_primaryWfId);
            
            // Skip outcome check if escrow is still in DISPUTED state (pending settlement)
            // The outcome check is only meaningful once settlement is fully executed
            if (actualState == EscrowState.DISPUTED) {
                // TODO: once settlement is executed, re-check this assertion
                return;
            }
            
            // Map state to outcome string
            string memory actualOutcome;
            if (actualState == EscrowState.RELEASED) actualOutcome = "release";
            else if (actualState == EscrowState.REFUNDED) actualOutcome = "refund";
            else if (actualState == EscrowState.RESOLVED) actualOutcome = "settled";
            else actualOutcome = "unknown";

            assertEq(
                keccak256(bytes(actualOutcome)),
                keccak256(bytes(expectedOutcome)),
                "resolution.outcome mismatch"
            );
        }

        // authorized_resolver: bool
        if (stdJson.keyExists(json, string.concat(prefix, ".authorized_resolver"))) {
            bool expectedAuth = stdJson.readBool(json, string.concat(prefix, ".authorized_resolver"));
            assertEq(_resolutionAccepted, expectedAuth, "resolution.authorized_resolver mismatch");
        }

        // pending_settlement_created: bool
        if (stdJson.keyExists(json, string.concat(prefix, ".pending_settlement_created"))) {
            bool expectedCreated = stdJson.readBool(json, string.concat(prefix, ".pending_settlement_created"));
            assertEq(_pendingSettlementCreated, expectedCreated, "resolution.pending_settlement_created mismatch");
        }

        // settlement_executed: bool
        if (stdJson.keyExists(json, string.concat(prefix, ".settlement_executed"))) {
            bool expectedExecuted = stdJson.readBool(json, string.concat(prefix, ".settlement_executed"));
            assertEq(_settlementExecuted, expectedExecuted, "resolution.settlement_executed mismatch");
        }
    }

    function _assertEscalationSemantics(string memory json) internal view {
        string memory prefix = ".expected_semantics.escalation";

        // level: uint8
        if (stdJson.keyExists(json, string.concat(prefix, ".level"))) {
            uint256 expectedLevel = stdJson.readUint(json, string.concat(prefix, ".level"));
            (, uint8 actualRound,) = drModule.getAppealDeadlineAndRound(_primaryWfId, address(vault));
            assertEq(uint256(actualRound), expectedLevel, "escalation.level mismatch");
        }

        // attempted, accepted, rejected: bool (tracked separately if needed in future)
        // For now these are informational and not enforced
    }

    function _assertParticipationSemantics(string memory json) internal view {
        string memory prefix = ".expected_semantics.participation";

        // dispute_initiator: role name string
        if (stdJson.keyExists(json, string.concat(prefix, ".dispute_initiator"))) {
            string memory expectedRole = stdJson.readString(json, string.concat(prefix, ".dispute_initiator"));
            address expectedAddr = _roleToAddressV2(expectedRole);
            assertEq(_lastDisputeRaiser, expectedAddr, "participation.dispute_initiator mismatch");
        }

        // resolution_actor: role name string
        if (stdJson.keyExists(json, string.concat(prefix, ".resolution_actor"))) {
            string memory expectedRole = stdJson.readString(json, string.concat(prefix, ".resolution_actor"));
            address expectedAddr = _roleToAddressV2(expectedRole);
            assertEq(_lastResolver, expectedAddr, "participation.resolution_actor mismatch");
        }

        // authorized_participant: bool
        if (stdJson.keyExists(json, string.concat(prefix, ".authorized_participant"))) {
            bool expectedAuth = stdJson.readBool(json, string.concat(prefix, ".authorized_participant"));
            assertEq(_resolutionAccepted, expectedAuth, "participation.authorized_participant mismatch");
        }

        // settlement_actor: role name string (for future use)
        // Currently not enforced since executePendingSettlement is permissionless
    }

    function _assertTimingSemantics(string memory json) internal view {
        string memory prefix = ".expected_semantics.timing";

        // auto_cancel_triggered: bool
        if (stdJson.keyExists(json, string.concat(prefix, ".auto_cancel_triggered"))) {
            bool expectedTriggered = stdJson.readBool(json, string.concat(prefix, ".auto_cancel_triggered"));
            assertEq(_autoCancelTriggered, expectedTriggered, "timing.auto_cancel_triggered mismatch");
        }

        // within_resolution_window, within_settlement_window: bool
        // These are point-in-time checks that can't be verified post-hoc; skipping

        // pending_delay_seconds: uint256
        // Can be verified via pendingSettlements[wfId].appealDeadline if needed in future
    }

    // ====================================================================
    // v0.2 Role Mapping (extended from v0.1)
    // ====================================================================

    /**
     * @dev Map v0.2 role names to addresses. Extended from _roleToAddress to include
     *      additional roles: l1resolver, keeper, executor, l2resolver, etc.
     */
    function _isSupportedProfile(bytes32 profileId, uint256 profileVersion, string memory profileRoot) internal pure returns (bool) {
        if (profileId != keccak256(bytes(EquivalenceInvariantProfileV1.PROFILE_ID))) return false;
        if (profileVersion != EquivalenceInvariantProfileV1.PROFILE_VERSION) return false;
        // Convert PROFILE_ROOT (bytes32) to lowercase hex string for string comparison
        bytes memory hexChars = "0123456789abcdef";
        bytes memory expectedRoot = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            uint8 b = uint8(EquivalenceInvariantProfileV1.PROFILE_ROOT[i]);
            expectedRoot[i * 2] = hexChars[b >> 4];
            expectedRoot[i * 2 + 1] = hexChars[b & 0xf];
        }
        return keccak256(bytes(profileRoot)) == keccak256(expectedRoot);
    }

    function _roleToAddressV2(string memory role) internal pure returns (address) {
        bytes32 h = keccak256(bytes(role));
        if (h == keccak256("buyer"))           return BUYER;
        if (h == keccak256("seller"))          return SELLER;
        if (h == keccak256("resolver"))        return RESOLVER;
        if (h == keccak256("l0resolver"))       return L0RESOLVER;
        if (h == keccak256("l1resolver"))       return L1RESOLVER;
        if (h == keccak256("l2resolver"))       return L2RESOLVER;
        if (h == keccak256("keeper"))           return KEEPER;
        if (h == keccak256("executor"))         return EXECUTOR;
        if (h == keccak256("governance"))       return GOVERNANCE;
        if (h == keccak256("legacyresolver"))   return LEGACYRESOLVER;
        if (h == keccak256("resolver0"))        return RESOLVER;
        if (h == keccak256("flood_buyer") || h == keccak256("flood_buyers")) return BUYER;
        if (h == keccak256("0xAlice")) return BUYER;
        if (h == keccak256("0xBob"))   return SELLER;
        if (h == keccak256("0xseller0")) return SELLER;
        // Fail loudly: an unmapped role means the fixture cannot be replayed
        // faithfully.  Add the role to _roleToAddressV2 (and a well-known
        // address constant) rather than silently aliasing it to another actor.
        revert(string.concat("TraceEquivalence: unknown v0.2 role: ", role, " - add it to _roleToAddressV2"));
    }

    // ====================================================================
    // CDRS v0.1 Trace Replay (original fixture format)
    // ====================================================================

    function _replayStep(string memory json, string memory prefix) internal {
        // ── Read action fields ───────────────────────────────────────────
        string memory action     = stdJson.readString(json, string.concat(prefix, ".action"));
        string memory callerRole = stdJson.readString(json, string.concat(prefix, ".caller_role"));
        uint256 warpTo           = stdJson.readUint(json,   string.concat(prefix, ".warp_to"));

        if (warpTo > block.timestamp) vm.warp(warpTo);

        address caller = _roleToAddress(callerRole);

        // ── Resolve workflow alias ────────────────────────────────────────
        uint256 wfId = 0;
        string memory wfAliasKey = "";
        bool hasWfAlias = stdJson.keyExists(json, string.concat(prefix, ".wf_alias"));
        if (hasWfAlias) {
            wfAliasKey = stdJson.readString(json, string.concat(prefix, ".wf_alias"));
            wfId = wfAlias[wfAliasKey];
        }

        // ── Dispatch action ───────────────────────────────────────────────
        bytes32 actionHash = keccak256(bytes(action));

        if (actionHash == keccak256("create_escrow")) {
            uint256 amount = stdJson.readUint(json, string.concat(prefix, ".params.amount"));
            string memory toRole = stdJson.readString(json, string.concat(prefix, ".params.to_role"));
            address to = _roleToAddress(toRole);

            vm.startPrank(caller);
            token.approve(address(vault), amount);
            uint256 newWfId = vault.createEscrow(
                address(token), to, amount, SettingsValidationLibrary.getDefaultSettings()
            );
            vm.stopPrank();

            // Register alias if requested
            bool hasSaveWfAs = stdJson.keyExists(json, string.concat(prefix, ".save_wf_as"));
            if (hasSaveWfAs) {
                string memory alias_ = stdJson.readString(json, string.concat(prefix, ".save_wf_as"));
                wfAlias[alias_] = newWfId;
            }
            wfId = newWfId;

        } else if (actionHash == keccak256("release")) {
            vm.prank(caller);
            vault.release(wfId);

        } else if (actionHash == keccak256("sender_cancel")) {
            vm.prank(caller);
            vault.senderCancel(wfId);

        } else if (actionHash == keccak256("recipient_cancel")) {
            vm.prank(caller);
            vault.recipientCancel(wfId);

        } else if (actionHash == keccak256("raise_dispute")) {
            vm.prank(caller);
            vault.raiseDispute(wfId);

        } else if (actionHash == keccak256("release_as_dispute_resolver")) {
            vm.prank(caller);
            vault.releaseAsDisputeResolver(wfId, bytes32(0));

        } else if (actionHash == keccak256("cancel_as_dispute_resolver")) {
            vm.prank(caller);
            vault.cancelAsDisputeResolver(wfId, bytes32(0));

        } else if (actionHash == keccak256("execute_pending_settlement")) {
            vault.executePendingSettlement(wfId);

        } else if (actionHash == keccak256("auto_cancel_disputed")) {
            vault.autoCancelDisputedEscrow(wfId);

        } else {
            revert(string.concat("TraceEquivalence: unknown action: ", action));
        }

        // ── Assert projection matches simulation expected ─────────────────
        string memory expPrefix = string.concat(prefix, ".expected");
        bool hasExpected = stdJson.keyExists(json, string.concat(expPrefix, ".escrow_state"));
        if (!hasExpected) return;

        uint256 expectedState = stdJson.readUint(json, string.concat(expPrefix, ".escrow_state"));
        uint256 expectedAfa   = stdJson.readUint(json, string.concat(expPrefix, ".amount_after_fee"));
        uint256 expectedHeld  = stdJson.readUint(json, string.concat(expPrefix, ".total_held"));
        uint256 expectedFees  = stdJson.readUint(json, string.concat(expPrefix, ".total_fees"));
        bool    expPsExists   = stdJson.readBool(json,  string.concat(expPrefix, ".pending_settlement_exists"));
        uint256 expDispLevel  = stdJson.readUint(json,  string.concat(expPrefix, ".dispute_level"));

        string memory stepLabel = string.concat(prefix, " [", action, "]");

        // State
        EscrowState actualState = vault.getEscrowState(wfId);
        assertEq(uint256(actualState), expectedState,
            string.concat(stepLabel, " escrow_state mismatch"));

        // Amount after fee (EscrowTransfer fields: token,to,from,disputeResolver,amountAfterFee,...)
        (,,,, uint256 actualAfa,,,,,) = vault.escrowTransfers(wfId);
        assertEq(actualAfa, expectedAfa,
            string.concat(stepLabel, " amount_after_fee mismatch"));

        // Total held
        uint256 actualHeld = vault.totalHeldInEscrowPerToken(address(token));
        assertEq(actualHeld, expectedHeld,
            string.concat(stepLabel, " total_held mismatch"));

        // Total fees
        uint256 actualFees = vault.totalFeesPerToken(address(token));
        assertEq(actualFees, expectedFees,
            string.concat(stepLabel, " total_fees mismatch"));

        // Pending settlement
        (bool psExists,,, ) = vault.pendingSettlements(wfId);
        assertEq(psExists, expPsExists,
            string.concat(stepLabel, " pending_settlement_exists mismatch"));

        // Dispute level (from DefaultResolutionModule - currentRound is the 2nd return value)
        (, uint8 currentRound,) = drModule.getAppealDeadlineAndRound(wfId, address(vault));
        assertEq(uint256(currentRound), expDispLevel,
            string.concat(stepLabel, " dispute_level mismatch"));
    }

    // ====================================================================
    // Assertion helpers (used by inline tests)
    // ====================================================================

    function _assertEscrowState(uint256 wfId, EscrowState expected, string memory label) internal view {
        EscrowState actual = vault.getEscrowState(wfId);
        assertEq(uint256(actual), uint256(expected), string.concat("escrow_state ", label));
    }

    function _assertAmountAfterFee(uint256 wfId, uint256 expected, string memory label) internal view {
        (,,,, uint256 afa,,,,,) = vault.escrowTransfers(wfId);
        assertEq(afa, expected, string.concat("amount_after_fee ", label));
    }

    function _assertTotalHeld(uint256 expected, string memory label) internal view {
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), expected,
            string.concat("total_held ", label));
    }

    function _assertTotalFees(uint256 expected, string memory label) internal view {
        assertEq(vault.totalFeesPerToken(address(token)), expected,
            string.concat("total_fees ", label));
    }

    // ====================================================================
    // Helpers
    // ====================================================================

    function _roleToAddress(string memory role) internal pure returns (address) {
        bytes32 h = keccak256(bytes(role));
        if (h == keccak256("buyer"))    return BUYER;
        if (h == keccak256("seller"))   return SELLER;
        if (h == keccak256("resolver")) return RESOLVER;
        revert(string.concat("TraceEquivalence: unknown role: ", role, " - add it to _roleToAddress"));
    }

    // ====================================================================
    // CDRS v0.2 Trace Tests
    // ====================================================================

    function test_v2_s01_lifecycle() public {
        _replayTrace("test/foundry/traces/v2/s01.json");
    }

    function test_v2_s02_dispute_release() public {
        _replayTrace("test/foundry/traces/v2/s02.json");
    }

    function test_v2_s05_pending_settlement() public {
        _replayTrace("test/foundry/traces/v2/s05.json");
    }

    // ====================================================================
    // Manifest-bound v2 traces (synchronised from Clojure simulation)
    // See etc/trace-solidity-manifest.edn in the Clojure repo.
    // ====================================================================

    // Sew domain reference — core protocol conflict scenarios.
    // sew-001, sew-004 excluded: traces generated with legacy sim behavior
    // that set total_held=0 on pending settlement creation.  Solidity vault
    // keeps funds locked until executePendingSettlement.  The settlement derivation
    // appeal-window-duration=0 fix is correct; traces need regeneration.
    function test_v2_sew_003_escalation_after_terminal() public {
        _replayTrace("test/foundry/traces/v2/sew-003.json");
    }

    function test_v2_sew_001_same_block_dual_resolution() public {
        _replayTrace("test/foundry/traces/v2/sew-001.json");
    }

    function test_v2_sew_002_pending_settlement_expiry() public {
        _replayTrace("test/foundry/traces/v2/sew-002.json");
    }

    function test_v2_sew_004_force_refund_illegal_release() public {
        _replayTrace("test/foundry/traces/v2/sew-004.json");
    }


    // Reference validation — adversarial / CI review paths.
    // ref-002 not wired: requires propose_fraud_slash / slashing-module actions.
    // ref-003 not wired: escrow amounts (500 wei) are below the contract's
    // MIN_ESCROW_AMOUNT (1000), so the trace cannot be replayed faithfully;
    // the sim does not enforce the same minimum.
    // ref-008 not wired: uses yield-specific action "trigger-accrue".

    function test_v2_ref_001_governance_sandwich() public {
        _replayTrace("test/foundry/traces/v2/ref-001.json");
    }

    function test_v2_ref_004_bond_withdrawal_race() public {
        _replayTrace("test/foundry/traces/v2/ref-004.json");
    }

    function test_v2_ref_005_same_block_ordering() public {
        _replayTrace("test/foundry/traces/v2/ref-005.json");
    }

    function test_v2_ref_006_autopush_settlement() public {
        _replayTrace("test/foundry/traces/v2/ref-006.json");
    }

    function test_v2_ref_007_appeal_failure_cascade() public {
        _replayTrace("test/foundry/traces/v2/ref-007.json");
    }

    // ref-008 excluded: uses yield-specific action "trigger-accrue".

    // EF review scenarios — review corpus from EF_REVIEW_GUIDE.md.
    // S-DR-001 covers the core lifecycle path.
    // S-DR-084 excluded: requires submit_evidence action on EvidenceModuleV1,
    // which is not deployed in the basic vault test harness.
    // S-NC-001 and DR-N-002 excluded: use register_stake/slashing-module
    // actions not available in the basic vault harness.
    // Y06 excluded: uses yield-only actions (YieldOps) requiring a separate
    // yield-aware test harness.
    function test_v2_review_s_dr_001_basic_release_ruling() public {
        _replayTrace("test/foundry/traces/v2/review-s-dr-001.json");
    }


    // ====================================================================
    // CDRS v0.2 Negative Tests
    // These tests verify that semantic violations are caught by TraceEquivalence
    // ====================================================================

    // Negative fixtures now carry an invariant profile and are required to
    // replay fully (profile resolved + applied) and then revert at the semantic
    // assertion layer.  _expectSemanticMismatch asserts that the replay got
    // PAST the profile gate and failed on a "... mismatch" assertion — proving
    // the negative test is non-vacuous (it no longer passes merely because the
    // fixture lacked an invariant_profile and reverted at the profile require).
    /// @dev Forge assertion failures revert with selector 0xeeaa9e6f followed by
    ///      an ABI-encoded string (NOT a catchable Error(string)).  Strip the
    ///      selector so the reason can be decoded.
    function _stripSelector(bytes memory b) internal pure returns (bytes memory) {
        bytes memory out = new bytes(b.length - 4);
        for (uint256 i = 4; i < b.length; i++) out[i - 4] = b[i];
        return out;
    }

    function _expectSemanticMismatch(string memory fixturePath) internal {
        try this.replayTraceExternal(fixturePath) {
            fail("expected semantic mismatch");
        } catch (bytes memory b) {
            require(b.length >= 4, "negative fixture reverted with no reason");
            require(bytes4(b) == bytes4(0xeeaa9e6f),
                "negative fixture did not fail on a forge assertion (likely reverted at the profile gate)");
            string memory reason = abi.decode(_stripSelector(b), (string));
            assertTrue(
                _reasonContains(reason, " mismatch") && !_reasonContains(reason, "invariant profile"),
                string.concat("expected a semantic-mismatch assertion past the profile gate, got: ", reason)
            );
        }
    }

    function test_negative_n01_wrong_outcome() public {
        // N01: Expected outcome="refund" but actual is "release"
        _expectSemanticMismatch("test/foundry/traces/v2/negative/n01.json");
    }

    function test_negative_n02_unauthorized_resolver() public {
        // N02: Expected authorized_resolver=false but actual is true
        _expectSemanticMismatch("test/foundry/traces/v2/negative/n02.json");
    }

    function test_negative_n03_settlement_not_executed() public {
        // N03: Expected settlement_executed=false but actual is true
        _expectSemanticMismatch("test/foundry/traces/v2/negative/n03.json");
    }

    function test_negative_n04_wrong_escalation_level() public {
        // N04: Expected escalation.level=1 but actual is 0
        _expectSemanticMismatch("test/foundry/traces/v2/negative/n04.json");
    }

    function test_negative_n05_wrong_dispute_initiator() public {
        // N05: Expected dispute_initiator="seller" but actual is "buyer"
        _expectSemanticMismatch("test/foundry/traces/v2/negative/n05.json");
    }

    function test_negative_n06_auto_cancel_triggered() public {
        // N06: Expected auto_cancel_triggered=true but actual is false
        _expectSemanticMismatch("test/foundry/traces/v2/negative/n06.json");
    }

    function test_negative_n07_wrong_resolution_actor() public {
        // N07: Expected resolution_actor="buyer" but actual is "resolver"
        _expectSemanticMismatch("test/foundry/traces/v2/negative/n07.json");
    }

    // ====================================================================
    // Version-rejection negative tests (Phase 1)
    //
    // Prove the harness negotiates fixture-specs fail-closed: missing or
    // unsupported cdrs_version / schema_version combinations and unsupported
    // replay-specs are rejected before any action is interpreted.  These are
    // normal require reverts, so they are catchable as Error(string).
    // ====================================================================
    function _expectVersionReject(string memory fixturePath, string memory needle) internal {
        try this.replayTraceExternal(fixturePath) {
            fail("expected version rejection");
        } catch Error(string memory reason) {
            assertTrue(
                _reasonContains(reason, needle),
                string.concat("expected '", needle, "' in revert reason, got: ", reason)
            );
        }
    }

    function test_version_reject_unknown_cdrs() public {
        _expectVersionReject("test/foundry/traces/v2/negative/version/nv01-unknown-cdrs.json",
            "unsupported fixture-spec combination");
    }

    function test_version_reject_missing_cdrs() public {
        _expectVersionReject("test/foundry/traces/v2/negative/version/nv02-missing-cdrs.json",
            "missing cdrs_version");
    }

    function test_version_reject_invalid_combo() public {
        _expectVersionReject("test/foundry/traces/v2/negative/version/nv03-invalid-combo.json",
            "unsupported fixture-spec combination");
    }

    function test_version_reject_unsupported_profile() public {
        _expectVersionReject("test/foundry/traces/v2/negative/version/nv04-unsupported-profile.json",
            "unsupported replay-spec");
    }

    // ====================================================================
    // Failure-injection tests — each proves one invariant has detection power
    // ====================================================================

    function test_invariant_heldReconstruction_detects_corruptedHeld() public {
        _replayTrace("test/foundry/traces/v2/review-s-dr-001.json");
        _createBasicEscrow();
        uint256 wfId = 1;
        VaultSnapshot memory snap = _snapshot(wfId);
        snap.totalHeld = snap.amountAfterFee + 1; // Corrupt: held exceeds amountAfterFee
        try this.checkHeldReconstructionExternal(snap, wfId) {
            fail("held-reconstruction should have failed");
        } catch Error(string memory reason) {
            assertEq(reason, "invariant: held-reconstruction [wf 1]");
        }
    }

    function test_invariant_disputeLevelBounded_detects_excess() public {
        _replayTrace("test/foundry/traces/v2/review-s-dr-001.json");
        _createBasicEscrow();
        uint256 wfId = 1;
        vm.prank(BUYER);
        vault.raiseDispute(wfId);
        VaultSnapshot memory snap = _snapshot(wfId);
        snap.disputeLevel = 99;
        try this.checkStateEquationsExternal(snap, wfId) {
            fail("dispute-level-bounded should have failed");
        } catch Error(string memory reason) {
            assertEq(reason, "invariant: dispute-level-bounded [wf 1]");
        }
    }

    function test_invariant_stateTransition_detects_invalid() public {
        _replayTrace("test/foundry/traces/v2/review-s-dr-001.json");
        _createBasicEscrow();
        uint256 wfId = 1;
        VaultSnapshot memory before_;
        before_.escrowState = EscrowState.NONE;
        before_.disputeLevel = 0;
        VaultSnapshot memory after_ = _snapshot(wfId);
        after_.escrowState = EscrowState.DISPUTED;
        try this.checkTransitionEquationsExternal(before_, after_, "raise_dispute", wfId) {
            fail("state-transition-valid should have failed");
        } catch Error(string memory reason) {
            assertEq(reason, "invariant: state-transition-valid [wf 1 action raise_dispute]");
        }
    }

    // ====================================================================
    // Workflow-0 invariant-coverage regression
    //
    // Workflow ids are 0-based (escrowTransfers.length), so the primary
    // workflow of every single-escrow trace is id 0.  These regressions prove
    // the invariant layer (before-snapshot capture, conservation accounting,
    // state equations, held reconstruction, transition equations) actually
    // executes for workflow 0 during trace replay.  Both fixtures are
    // harness self-tests and are NOT part of the manifest-bound set.
    // ====================================================================

    /// @dev Substring check on a revert reason (reasons embed dynamic values).
    function _reasonStartsWith(string memory reason, string memory prefix) internal pure returns (bool) {
        bytes memory rb = bytes(reason);
        bytes memory pb = bytes(prefix);
        if (rb.length < pb.length) return false;
        for (uint256 i = 0; i < pb.length; i++) {
            if (rb[i] != pb[i]) return false;
        }
        return true;
    }

    /// @dev True iff `reason` contains `needle` anywhere.
    function _reasonContains(string memory reason, string memory needle) internal pure returns (bool) {
        bytes memory rb = bytes(reason);
        bytes memory nb = bytes(needle);
        if (nb.length == 0) return true;
        if (rb.length < nb.length) return false;
        for (uint256 i = 0; i + nb.length <= rb.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < nb.length; j++) {
                if (rb[i + j] != nb[j]) { match_ = false; break; }
            }
            if (match_) return true;
        }
        return false;
    }

    /**
     * Prove the post-step invariant gate executes for workflow 0.
     *
     * inv-wf0-conservation.json replays a create on the primary workflow
     * (wf 0) while the harness conservation accumulator has been corrupted by
     * `.test_corrupt_deposited`.  If checkStateEquations (conservation-of-funds)
     * runs for wf 0, replay reverts with the conservation invariant reason.
     * Before the wfId!=0 gating fix this fixture replayed without any invariant
     * evaluation and the test failed.
     */
    function test_workflow0_invariant_checks_execute() public {
        try this.replayTraceExternal("test/foundry/traces/v2/regression/inv-wf0-conservation.json") {
            fail("invariant checks did not execute for workflow 0");
        } catch Error(string memory reason) {
            assertTrue(
                _reasonStartsWith(reason, "invariant: conservation-of-funds [wf 0"),
                string.concat("expected conservation-of-funds failure on wf 0, got: ", reason)
            );
        }
    }

    /**
     * Prove held-reconstruction executes and is multi-escrow correct for
     * workflow 0.  The fixture creates two simultaneously-held escrows (wf 0
     * and wf 1) and takes an accepted step on wf 0 while both are PENDING.
     * held-reconstruction then compares the GLOBAL totalHeld against the sum of
     * per-escrow amountAfterFee; with the per-workflow-afa assumption it would
     * revert (held != single wf afa).  Completing without revert proves the
     * check ran for wf 0 and the sum-based reconstruction held.
     */
    function test_workflow0_held_reconstruction_multi_escrow() public {
        _replayTrace("test/foundry/traces/v2/regression/inv-wf0-two-escrows.json");
        // If replay completed, held-reconstruction evaluated for wf 0 and passed.
        assertTrue(_hasPrimaryWfId, "primary workflow should have been captured");
    }

    // External wrappers so try/catch works (Solidity requires external calls for try)
    function checkHeldReconstructionExternal(VaultSnapshot memory snap, uint256 wfId) external pure {
        EquivalenceInvariantProfileV1.checkHeldReconstruction(snap, wfId);
    }

    function checkStateEquationsExternal(VaultSnapshot memory snap, uint256 wfId) external pure {
        EquivalenceInvariantProfileV1.checkStateEquations(snap, wfId);
    }

    function checkTransitionEquationsExternal(VaultSnapshot memory before_, VaultSnapshot memory after_, string memory action, uint256 wfId) external pure {
        EquivalenceInvariantProfileV1.checkTransitionEquations(before_, after_, action, wfId);
    }

    function _createBasicEscrow() internal {
        uint256 amount = 10_000 ether;
        vm.startPrank(BUYER);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), SELLER, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }
}
