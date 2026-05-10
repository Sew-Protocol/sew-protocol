// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./EscrowInvariantHandler.t.sol";
import "../../../contracts/types/EscrowTypes.sol";
/// @notice Foundry invariant tests for resolver authority and appeal window enforcement.
///
/// Invariants:
///   4. resolver_exclusivity — when customResolver is set, only that address can resolve
///   5. appeal_window        — executePendingSettlement before appealDeadline always reverts
///
/// These match the Clojure predicates:
///   - auth/authorized-resolver? (custom-resolver path)
///   - res/execute-pending-settlement (:appeal-window-not-expired guard)
///
/// Two separate handler configurations are used:
///   - CustomResolverHandler: creates escrows with a fixed customResolver
///   - AppealWindowHandler: creates escrows with appeal window > 0
contract ResolverInvariants is Test {

    // =========================================================================
    // Setup 4: Resolver exclusivity
    //
    // We set customResolver = resolver on every escrow and assert that the
    // "rogue" address can never drive a resolution to completion.
    // =========================================================================

    EscrowVault     internal vault4;
    ERC20Mock       internal token4;
    DefaultResolutionModule internal resModule4;
    EscrowInvariantHandler  internal handler4;

    YieldOps     internal y4;
    DisputeOps   internal d4;
    SettlementOps internal s4;
    CreateOps    internal c4;
    BondCollector internal b4;
    ModuleSnapshotRegistry internal mm4;

    address internal feeAddr4   = address(0x4004);
    address internal resolver4  = address(0x4003);
    address internal rogue4     = address(0x4999); // must NOT be able to resolve

    function setUp() public {
        _setupVault4();
    }

    function _setupVault4() internal {
        token4 = new ERC20Mock("Token4", "TKN4", address(this), 0);
        y4 = new YieldOps(address(this));
        d4 = new DisputeOps(address(this));
        s4 = new SettlementOps(address(this));
        c4 = new CreateOps(address(this));
        b4 = new BondCollector(address(this));
        mm4 = new ModuleSnapshotRegistry(address(this));
        resModule4 = new DefaultResolutionModule(address(this), resolver4);

        vault4 = new EscrowVault(100, feeAddr4, address(y4), address(d4), address(mm4));
        y4.registerEscrowContract(address(vault4));
        d4.registerEscrowContract(address(vault4));
        s4.registerEscrowContract(address(vault4));
        c4.registerEscrowContract(address(vault4));
        b4.registerEscrowContract(address(vault4));
        mm4.registerEscrowContract(address(vault4));

        vault4.grantRole(vault4.ROLE_ADMIN_CONTRACT(), address(this));
        vault4.setCreateOps(address(c4));
        vault4.setSettlementOps(address(s4));
        vault4.setBondCollector(address(b4));
        vault4.setResolutionModule(address(resModule4));
        vault4.grantRole(vault4.ROLE_FEE_RECIPIENT(), feeAddr4);

        handler4 = new EscrowInvariantHandler(vault4, token4, resModule4);
        vault4.grantRole(vault4.ROLE_ADMIN_CONTRACT(), address(handler4));

        targetContract(address(handler4));
    }

    // -------------------------------------------------------------------------
    // Invariant 4: Resolver exclusivity
    //
    // Mirrors: auth/authorized-resolver? (custom-resolver branch)
    //
    // The DefaultResolutionModule is configured with resolver4 as the sole
    // authorized address. The "rogue" address attempting to call
    // releaseAsDisputeResolver / cancelAsDisputeResolver must always revert.
    //
    // We verify this by attempting the call directly inside the invariant check
    // (not relying on the handler, so the fuzzer can't accidentally provide the
    // correct address).
    // -------------------------------------------------------------------------
    function invariant_resolver_exclusivity() public {
        uint256 count = vault4.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            (,,,,,,, EscrowState st,,) = vault4.escrowTransfers(i);
            if (st != EscrowState.DISPUTED) continue;

            // Rogue address attempts release — must revert
            vm.prank(rogue4);
            try vault4.releaseAsDisputeResolver(i, bytes32(0)) {
                revert(
                    string.concat(
                        "RESOLVER_EXCLUSIVITY: rogue resolved workflowId ",
                        vm.toString(i)
                    )
                );
            } catch {
                // expected — rogue correctly rejected
            }

            // Rogue address attempts refund — must revert
            vm.prank(rogue4);
            try vault4.cancelAsDisputeResolver(i, bytes32(0)) {
                revert(
                    string.concat(
                        "RESOLVER_EXCLUSIVITY: rogue cancelled workflowId ",
                        vm.toString(i)
                    )
                );
            } catch {
                // expected
            }
        }
    }
}

/// @title AppealWindowInvariants
/// @notice Separate invariant suite for appeal window enforcement.
///
/// Uses its own vault wired with a DecentralizedResolutionModule-like setup
/// that sets appealWindowDuration > 0. The handler resolves disputes to
/// create PendingSettlements; the invariant asserts early execution always fails.
contract AppealWindowInvariants is Test {

    EscrowVault     internal vault;
    ERC20Mock       internal token;
    DefaultResolutionModule internal resModule;
    EscrowInvariantHandler  internal handler;

    YieldOps     internal yieldOps;
    DisputeOps   internal disputeOps;
    SettlementOps internal settlementOps;
    CreateOps    internal createOps;
    BondCollector internal bondCollector;
    ModuleSnapshotRegistry internal mm;

    address internal feeAddr  = address(0x5004);
    address internal resolver = address(0x5003);

    function setUp() public {
        token = new ERC20Mock("AppealToken", "ATP", address(this), 0);

        yieldOps     = new YieldOps(address(this));
        disputeOps   = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps    = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        mm           = new ModuleSnapshotRegistry(address(this));
        resModule    = new DefaultResolutionModule(address(this), resolver);

        vault = new EscrowVault(100, feeAddr, address(yieldOps), address(disputeOps), address(mm));

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

        // Wire appeal window via vault.setTimeoutConfig (7-day appeal window).
        // This is snapshotted into every escrow created after this point.
        vault.setTimeoutConfig(
            TimeoutConfig({
                defaultAutoReleaseDelay: 0,
                defaultAutoCancelDelay:  0,
                maxDisputeDuration:      30 days,
                appealWindowDuration:    7 days
            })
        );

        handler = new EscrowInvariantHandler(vault, token, resModule);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(handler));

        targetContract(address(handler));
    }

    // -------------------------------------------------------------------------
    // Invariant 5: Appeal window enforcement
    //
    // Mirrors: res/execute-pending-settlement (:appeal-window-not-expired guard)
    //
    // For every workflow with a live PendingSettlement where
    // block.timestamp < appealDeadline, executePendingSettlement must revert.
    // -------------------------------------------------------------------------
    function invariant_appeal_window_enforced() public {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            (,,,,,,, EscrowState st,,) = vault.escrowTransfers(i);
            if (st != EscrowState.DISPUTED) continue;

            // Read pending settlement via view (pendingSettlements mapping)
            (bool exists,, uint256 deadline,) = vault.pendingSettlements(i);
            if (!exists) continue;
            if (block.timestamp >= deadline) continue;

            // Attempt early execution — must revert
            try vault.executePendingSettlement(i) {
                revert(
                    string.concat(
                        "APPEAL_WINDOW: early execution succeeded for workflowId ",
                        vm.toString(i)
                    )
                );
            } catch {
                // expected — contract correctly blocked early execution
            }
        }
    }
}
