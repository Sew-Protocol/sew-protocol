// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";
import { EscrowVault } from "../../contracts/core/EscrowVault.sol";
import { EscrowViewContract } from "../../contracts/core/EscrowViewContract.sol";
import { DefaultResolutionModule } from "../../contracts/core/modules/DefaultResolutionModule.sol";
import { CreateOps } from "../../contracts/ops/CreateOps.sol";
import { SettlementOps } from "../../contracts/ops/SettlementOps.sol";
import { YieldOps } from "../../contracts/ops/YieldOps.sol";
import { DisputeOps } from "../../contracts/ops/DisputeOps.sol";
import { BondCollector } from "../../contracts/core/BondCollector.sol";
import { ModuleSnapshotRegistry } from "../../contracts/core/ModuleSnapshotRegistry.sol";
import { ERC20Mock } from "../../contracts/mocks/ERC20Mock.sol";
import { EscrowSettings, EscrowState } from "../../contracts/types/EscrowTypes.sol";
import { YieldPreset } from "../../contracts/types/YieldPresets.sol";
import { SettingsValidationLibrary } from "../../contracts/libraries/SettingsValidationLibrary.sol";

/**
 * @title TraceRegressionTest
 * @notice Forge test that replays every adversarial trace persisted by the
 *         Clojure simulation into test/foundry/traces/regression/.
 *
 * Workflow:
 *   1. Clojure simulation discovers a notable trace (high score / invariant
 *      violation / liveness failure).
 *   2. resolver-sim.io.trace-store/store-trace! persists it to results/traces/.
 *   3. resolver-sim.io.trace-store/promote-to-regression! copies the fixture
 *      JSON into test/foundry/traces/regression/.
 *   4. resolver-sim.io.trace-store/export-regression-manifest writes
 *      test/foundry/traces/regression/manifest.json listing file names.
 *   5. This test reads the manifest and replays every listed fixture.
 *
 * The test passes when every fixture replays cleanly with all EVM projections
 * matching the simulation expectations embedded in the fixture.
 *
 * An empty manifest (no regression fixtures yet) is not a failure.
 *
 * Fixture format: same as TraceEquivalence.t.sol (see test/foundry/traces/README.md).
 */
contract TraceRegressionTest is Test {
    using stdJson for string;

    // ── Contract instances ───────────────────────────────────────────────
    EscrowVault             vault;
    EscrowViewContract      oracle;
    DefaultResolutionModule drModule;
    CreateOps               createOps;
    SettlementOps           settlementOps;
    YieldOps                yieldOps;
    DisputeOps              disputeOps;
    BondCollector           bondCollector;
    ModuleSnapshotRegistry  moduleManagement;
    ERC20Mock               token;

    // ── Stable role addresses ────────────────────────────────────────────
    address internal owner;
    address constant BUYER    = address(0x1001);
    address constant SELLER   = address(0x1002);
    address constant RESOLVER = address(0x1234);
    address constant FEE_ADDR = address(0xFEE);

    // ── Per-trace state reset in _resetTrace() ───────────────────────────
    mapping(string => uint256) internal wfAlias;

    // ── Regression fixture directory ─────────────────────────────────────
    string constant REGRESSION_DIR      = "test/foundry/traces/regression";
    string constant REGRESSION_MANIFEST = "test/foundry/traces/regression/manifest.json";

    // ====================================================================
    // setUp — identical stack to TraceEquivalenceTest
    // ====================================================================
    function setUp() public {
        owner = address(this);

        token = new ERC20Mock("Regression USDC", "RUSDC", owner, 0);

        yieldOps         = new YieldOps(owner);
        disputeOps       = new DisputeOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        createOps        = new CreateOps(owner);
        settlementOps    = new SettlementOps(owner);
        bondCollector    = new BondCollector(owner);
        drModule         = new DefaultResolutionModule(owner, RESOLVER);

        vault = new EscrowVault(100, FEE_ADDR, address(yieldOps), address(disputeOps), address(moduleManagement));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        moduleManagement.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.setResolutionModule(address(drModule));

        oracle = new EscrowViewContract(address(vault));
        drModule.grantRole(drModule.ROLE_TIMELOCK(), owner);

        token.mint(BUYER,    100_000_000 ether);
        token.mint(SELLER,   100_000_000 ether);
        token.mint(RESOLVER, 100_000_000 ether);
    }

    // ====================================================================
    // Regression suite — reads manifest and replays all persisted fixtures
    // ====================================================================

    /**
     * @notice Replay every adversarial fixture in the regression manifest.
     *
     * Skips gracefully if the manifest is empty (no adversarial traces yet).
     * Fails on the first step that diverges from simulation expectations.
     */
    function test_regression_suite() public {
        string memory manifestRaw = vm.readFile(REGRESSION_MANIFEST);

        bytes memory fixturesRaw = stdJson.parseRaw(manifestRaw, ".fixtures");
        string[] memory fixtures = abi.decode(fixturesRaw, (string[]));
        uint256 fixtureCount = fixtures.length;

        if (fixtureCount == 0) {
            emit log("TraceRegressionTest: no regression fixtures yet - skipping");
            return;
        }

        emit log_named_uint("TraceRegressionTest: replaying regression fixtures", fixtureCount);

        for (uint256 i = 0; i < fixtureCount; i++) {
            string memory fixtureName = fixtures[i];
            string memory fixturePath = string.concat(REGRESSION_DIR, "/", fixtureName);
            emit log_named_string("  replaying", fixtureName);

            // Reset alias mapping between fixtures (Solidity mappings can't be
            // cleared, but aliases from previous traces won't match new wfIds)
            _replayTrace(fixturePath);
        }

        emit log_named_uint("TraceRegressionTest: all fixtures passed", fixtureCount);
    }

    // ====================================================================
    // Replay engine (mirrors TraceEquivalenceTest._replayTrace / _replayStep)
    // ====================================================================

    function _replayTrace(string memory fixturePath) internal {
        string memory raw = vm.readFile(fixturePath);
        uint256 stepCount = stdJson.readUint(raw, ".step_count");

        for (uint256 i = 0; i < stepCount; i++) {
            string memory prefix = string.concat(".steps[", vm.toString(i), "]");
            _replayStep(raw, prefix);
        }
    }

    function _replayStep(string memory json, string memory prefix) internal {
        string memory action     = stdJson.readString(json, string.concat(prefix, ".action"));
        string memory callerRole = stdJson.readString(json, string.concat(prefix, ".caller_role"));
        uint256 warpTo           = stdJson.readUint(json,   string.concat(prefix, ".warp_to"));

        if (warpTo > block.timestamp) vm.warp(warpTo);

        address caller = _roleToAddress(callerRole);

        uint256 wfId = 0;
        bool hasWfAlias = stdJson.keyExists(json, string.concat(prefix, ".wf_alias"));
        if (hasWfAlias) {
            string memory aliasKey = stdJson.readString(json, string.concat(prefix, ".wf_alias"));
            wfId = wfAlias[aliasKey];
        }

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

            bool hasSaveWfAs = stdJson.keyExists(json, string.concat(prefix, ".save_wf_as"));
            if (hasSaveWfAs) {
                string memory alias_ = stdJson.readString(json, string.concat(prefix, ".save_wf_as"));
                wfAlias[alias_] = newWfId;
            }
            wfId = newWfId;

        } else if (actionHash == keccak256("release")) {
            vm.prank(caller);
            vault.releaseEscrowTransfer(wfId);

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
            revert(string.concat("TraceRegressionTest: unknown action: ", action));
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

        EscrowState actualState = vault.getEscrowState(wfId);
        assertEq(uint256(actualState), expectedState,
            string.concat(stepLabel, " escrow_state mismatch"));

        (,,,, uint256 actualAfa,,,,,) = vault.escrowTransfers(wfId);
        assertEq(actualAfa, expectedAfa,
            string.concat(stepLabel, " amount_after_fee mismatch"));

        assertEq(vault.totalHeldInEscrowPerToken(address(token)), expectedHeld,
            string.concat(stepLabel, " total_held mismatch"));

        assertEq(vault.totalFeesPerToken(address(token)), expectedFees,
            string.concat(stepLabel, " total_fees mismatch"));

        (bool psExists,,,) = vault.pendingSettlements(wfId);
        assertEq(psExists, expPsExists,
            string.concat(stepLabel, " pending_settlement_exists mismatch"));

        (, uint8 currentRound,) = drModule.getAppealDeadlineAndRound(wfId, address(vault));
        assertEq(uint256(currentRound), expDispLevel,
            string.concat(stepLabel, " dispute_level mismatch"));
    }

    // ====================================================================
    // Helpers
    // ====================================================================

    function _roleToAddress(string memory role) internal pure returns (address) {
        bytes32 h = keccak256(bytes(role));
        if (h == keccak256("buyer"))    return BUYER;
        if (h == keccak256("seller"))   return SELLER;
        if (h == keccak256("resolver")) return RESOLVER;
        revert(string.concat("TraceRegressionTest: unknown role: ", role));
    }
}
