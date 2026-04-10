// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./EscrowInvariantHandler.t.sol";
import "../../../contracts/core/EscrowVaultAnalytics.sol";
import "../../../contracts/types/EscrowTypes.sol";

/// @title StateInvariants
/// @notice Foundry invariant tests derived from contract_model/invariants.clj.
///
/// Invariants:
///   1. solvency          — vault token balance >= held + fees at all times
///   2. terminal_absorbing — once RELEASED/REFUNDED/RESOLVED, state never changes
///   3. fees_monotone      — totalFeesPerToken never decreases between withdrawFees calls
///
/// These match the Clojure predicates:
///   - inv/solvency-holds?
///   - inv/terminal-states-unchanged?
///   - inv/fee-increased-or-equal?
///
/// Handler drives all lifecycle paths including the dispute/resolution branch
/// that was absent from the prior AccountingInvariants.t.sol.
contract StateInvariants is Test {
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

    address internal feeAddr  = address(0x1004);
    address internal resolver = address(0x1003);

    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public {
        token = new ERC20Mock("Token", "TKN", address(this), 0);

        yieldOps     = new YieldOps(address(this));
        disputeOps   = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps    = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        mm           = new ModuleSnapshotRegistry(address(this));
        resModule    = new DefaultResolutionModule(address(this), resolver);

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

        handler = new EscrowInvariantHandler(vault, token, resModule);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(handler));

        targetContract(address(handler));
    }

    // -------------------------------------------------------------------------
    // Invariant 1: Solvency
    //
    // Mirrors: inv/solvency-holds?
    //
    // token.balanceOf(vault) must always be >= totalHeldInEscrowPerToken + totalFeesPerToken.
    //
    // The EscrowVaultAnalytics.getAccountingBreakdown decomposes:
    //   contractBalance = principal + fees + yieldInBalance
    // so yieldInBalance = contractBalance - (principal + fees) >= 0 is the check.
    // -------------------------------------------------------------------------
    function invariant_solvency() public {
        (uint256 principal, uint256 fees, uint256 contractBalance,) =
            EscrowVaultAnalytics(address(vault)).getAccountingBreakdown(address(token));

        assertGe(
            contractBalance,
            principal + fees,
            "SOLVENCY: vault balance must cover held principal and fees"
        );
    }

    // -------------------------------------------------------------------------
    // Invariant 2: Terminal states are absorbing
    //
    // Mirrors: inv/terminal-states-unchanged?
    //
    // Once a workflow reaches RELEASED, REFUNDED, or RESOLVED, no subsequent
    // handler call may change it to any other state.
    // -------------------------------------------------------------------------
    function invariant_terminal_states_absorbing() public {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            if (!handler.ghostIsTerminal(i)) continue;

            EscrowState expected = handler.ghostTerminalState(i);
            (,,,,,,, EscrowState current,,) = vault.escrowTransfers(i);

            assertEq(
                uint256(current),
                uint256(expected),
                string.concat(
                    "IRREVERSIBILITY: terminal state changed for workflowId ",
                    vm.toString(i)
                )
            );
        }
    }

    // -------------------------------------------------------------------------
    // Invariant 3: Fee monotonicity
    //
    // Mirrors: inv/fee-increased-or-equal?
    //
    // totalFeesPerToken must be >= ghostFeesBefore after every non-withdraw action.
    // The handler resets ghostFeesBefore only in withdrawFees(), so between
    // any two non-withdraw calls the invariant measures monotonic growth.
    // -------------------------------------------------------------------------
    function invariant_fees_monotone() public {
        uint256 current = vault.totalFeesPerToken(address(token));
        assertGe(
            current,
            handler.ghostFeesBefore(),
            "FEE_MONOTONICITY: totalFeesPerToken decreased without a withdrawFees call"
        );
    }
}
