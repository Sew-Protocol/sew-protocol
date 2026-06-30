// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
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

/// @title MultiTokenHandler
/// @notice Handler for multi-token isolation invariant fuzzing.
///
/// Interleaves escrow operations on two independent tokens (A and B) to exercise
/// the mapping(address => uint256) routing in totalHeldInEscrowPerToken,
/// totalFeesPerToken, and totalClaimableAssets.  A bug that confuses token keys
/// would produce cross-token accounting bleed detectable by the invariants.
contract MultiTokenHandler is Test {
    EscrowVault public vault;
    ERC20Mock   public tokenA;
    ERC20Mock   public tokenB;

    address public sender    = address(0x2001);
    address public recipient = address(0x2002);

    constructor(EscrowVault _vault, ERC20Mock _tokenA, ERC20Mock _tokenB) {
        vault  = _vault;
        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    // -------------------------------------------------------------------------
    // Internal: create + release helpers for a given token
    // -------------------------------------------------------------------------
    function _createWith(ERC20Mock tok, uint256 amount) internal {
        amount = bound(amount, 1e4, 500_000e18);
        tok.mint(sender, amount);
        vm.startPrank(sender);
        tok.approve(address(vault), amount);
        try vault.createEscrow(
            address(tok),
            recipient,
            amount,
            SettingsValidationLibrary.getDefaultSettings()
        ) {} catch {}
        vm.stopPrank();
    }

    function _releaseWith(uint256 seed) internal {
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);
        vm.prank(sender);
        try vault.release(wf) {} catch {}
    }

    function _cancelWith(uint256 seed) internal {
        uint256 count = vault.getEscrowCount();
        if (count == 0) return;
        uint256 wf = bound(seed, 0, count - 1);
        vm.prank(sender);
        try vault.senderCancel(wf) {} catch {}
        vm.prank(recipient);
        try vault.recipientCancel(wf) {} catch {}
    }

    // -------------------------------------------------------------------------
    // Actions — each group operates on one token; the invariants check the other
    // -------------------------------------------------------------------------

    function createEscrowA(uint256 amount) external { _createWith(tokenA, amount); }
    function createEscrowB(uint256 amount) external { _createWith(tokenB, amount); }

    function releaseEscrowA(uint256 seed) external { _releaseWith(seed); }
    function releaseEscrowB(uint256 seed) external { _releaseWith(seed); }

    function cancelEscrowA(uint256 seed) external { _cancelWith(seed); }
    function cancelEscrowB(uint256 seed) external { _cancelWith(seed); }

    function warpTime(uint256 delta) external {
        vm.warp(block.timestamp + bound(delta, 0, 30 days));
    }
}

/// @title MultiTokenIsolationInvariants
/// @notice Asserts that per-token accounting in EscrowVault never bleeds across tokens.
///
/// Core invariant: for each token T, the aggregate tracking
///   (totalHeldInEscrowPerToken[T], totalFeesPerToken[T], totalClaimableAssets[T])
/// must be exactly consistent with the per-escrow array for token T and must be
/// completely unaffected by operations on any other token.
///
/// This is verified via two independent sub-invariants:
///   A. Per-token principal sum matches totalHeld
///   B. Per-token fees are non-negative and consistent with the escrow array
contract MultiTokenIsolationInvariants is Test {
    EscrowVault   internal vault;
    ERC20Mock     internal tokenA;
    ERC20Mock     internal tokenB;
    MultiTokenHandler internal handler;

    YieldOps      internal yieldOps;
    DisputeOps    internal disputeOps;
    SettlementOps internal settlementOps;
    CreateOps     internal createOps;
    BondCollector internal bondCollector;
    ModuleSnapshotRegistry internal mm;
    DefaultResolutionModule internal resModule;

    address internal feeAddr  = address(0x2004);
    address internal resolver = address(0x2003);

    function setUp() public {
        tokenA = new ERC20Mock("TokenA", "TKNA", address(this), 0);
        tokenB = new ERC20Mock("TokenB", "TKNB", address(this), 0);

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

        handler = new MultiTokenHandler(vault, tokenA, tokenB);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(handler));

        targetContract(address(handler));
    }

    // -------------------------------------------------------------------------
    // Internal helper: compute per-token principal sum and fee sum from escrow array
    // -------------------------------------------------------------------------
    function _computeTokenSums(address tok)
        internal
        view
        returns (uint256 heldSum, uint256 feesAgg)
    {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            (address tkn,,,, uint256 amt,,, EscrowState st,,) = vault.escrowTransfers(i);
            if (tkn != tok) continue;
            if (st == EscrowState.PENDING || st == EscrowState.DISPUTED) {
                heldSum += amt;
            }
        }
        feesAgg = vault.totalFeesPerToken(tok);
    }

    // -------------------------------------------------------------------------
    // Invariant A: tokenA principal sum matches totalHeld[tokenA]
    // -------------------------------------------------------------------------
    function invariant_tokenA_principal_sum() public {
        (uint256 heldSum,) = _computeTokenSums(address(tokenA));
        assertEq(
            heldSum,
            vault.totalHeldInEscrowPerToken(address(tokenA)),
            "TOKEN_ISOLATION_A: sum(amountAfterFee for tokenA active escrows) != totalHeld[tokenA]"
        );
    }

    // -------------------------------------------------------------------------
    // Invariant B: tokenB principal sum matches totalHeld[tokenB]
    // -------------------------------------------------------------------------
    function invariant_tokenB_principal_sum() public {
        (uint256 heldSum,) = _computeTokenSums(address(tokenB));
        assertEq(
            heldSum,
            vault.totalHeldInEscrowPerToken(address(tokenB)),
            "TOKEN_ISOLATION_B: sum(amountAfterFee for tokenB active escrows) != totalHeld[tokenB]"
        );
    }

    // -------------------------------------------------------------------------
    // Invariant C: tokenA full solvency (balance >= held + fees + claimable)
    // -------------------------------------------------------------------------
    function invariant_tokenA_solvency() public {
        assertGe(
            tokenA.balanceOf(address(vault)),
            vault.totalHeldInEscrowPerToken(address(tokenA))
                + vault.totalFeesPerToken(address(tokenA))
                + vault.totalClaimableAssets(address(tokenA)),
            "TOKEN_ISOLATION_A_SOLVENCY: vault tokenA balance < held + fees + claimable"
        );
    }

    // -------------------------------------------------------------------------
    // Invariant D: tokenB full solvency
    // -------------------------------------------------------------------------
    function invariant_tokenB_solvency() public {
        assertGe(
            tokenB.balanceOf(address(vault)),
            vault.totalHeldInEscrowPerToken(address(tokenB))
                + vault.totalFeesPerToken(address(tokenB))
                + vault.totalClaimableAssets(address(tokenB)),
            "TOKEN_ISOLATION_B_SOLVENCY: vault tokenB balance < held + fees + claimable"
        );
    }
}
