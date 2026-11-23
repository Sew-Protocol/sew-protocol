// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import '../../../packages/sew-core/contracts/core/BaseEscrow.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import '../../../packages/sew-core/contracts/core/ModuleSnapshotRegistry.sol';
import '../../../packages/sew-core/contracts/core/EscrowCreationPolicy.sol';
import '../../../packages/sew-core/contracts/modules/DefaultReleaseStrategy.sol';
import '../../../packages/sew-core/contracts/types/EscrowTypes.sol';
import '../../../packages/sew-core/contracts/types/YieldPresets.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @notice Escrow-level end-to-end: EscrowVault ↔ AaveYieldModule.
/// @dev Regression for the deposit-funding model: the escrow only approves the
///      module (pull model), and the module must pull the requested amount.
contract AaveEscrowE2ETest is Test {
    EscrowVault internal vault;
    AaveYieldModule internal aaveModule;
    MockAavePool internal pool;
    MockAToken internal aToken;
    ERC20Mock internal token;
    ModuleSnapshotRegistry internal registry;
    EscrowCreationPolicy internal policy;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        token = new ERC20Mock('Token', 'TKN', address(this), 0);
        aToken = new MockAToken(address(token), 'aTKN', 'aTKN');
        pool = new MockAavePool();
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));

        aaveModule = new AaveYieldModule(address(pool));
        _cfgToken(address(token), address(aToken));

        registry = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));

        vault = new EscrowVault(0, FEE, address(registry));
        _approve(address(vault));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        // Preserve these E2E tests' intent of distributing FULL yield to the beneficiary:
        // disable the 30% default protocol yield fee (snapshotted at escrow creation)
        // before any escrow is created. Dedicated protocol-fee coverage lives in
        // AaveYieldProtocolFee test.
        vault.setYieldProtocolFeeBps(0);
        vault.setCreationPolicy(address(policy));

        registry.registerEscrowContract(address(vault));

        // Make the Aave module the default YIELD_GEN module for the vault, and register a
        // default RELEASE strategy so the release path can be exercised.
        registry.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        registry.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(new DefaultReleaseStrategy()));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        token.mint(BUYER, 1_000_000e18);
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
    }

    function _settings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.ENABLED,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    function _approve(address escrow_) internal {
        aaveModule.queueApproveEscrow(escrow_);
        (, uint64 eta, ) = aaveModule.getPendingApproveEscrow();
        vm.warp(eta);
        aaveModule.activateApproveEscrow();
    }

    function _cfgToken(address token_, address aToken_) internal {
        aaveModule.queueConfigureToken(token_, aToken_);
        (, uint64 eta, ) = aaveModule.getPendingConfigureToken(token_);
        vm.warp(eta);
        aaveModule.activateConfigureToken(token_);
    }

    function test_escrowLevel_aave_deposit_then_cancel_unwinds() public {
        uint256 buyerBalBefore = token.balanceOf(BUYER);

        vm.prank(BUYER);
        uint256 wf = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());

        // Deposit recorded; escrow pulled the amount from the buyer and the
        // module holds the Aave position.
        assertEq(vault.v25YieldModules(wf), address(aaveModule), 'yield module recorded');
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'yield principal recorded');
        assertGt(aToken.balanceOf(address(aaveModule)), 0, 'module holds aTokens');
        assertEq(token.balanceOf(address(vault)), 0, 'escrow forwarded the full amount to yield');
        assertEq(buyerBalBefore - token.balanceOf(BUYER), AMOUNT, 'buyer funded exactly AMOUNT');

        // Simulate yield, then mutually cancel: sender (ENABLED) receives principal + yield.
        pool.simulateYield(address(token), 10);

        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound');
        uint256 claimable = vault.claimableBalances(wf, BUYER);
        assertGt(claimable, AMOUNT, 'sender claimable exceeds principal (yield ENABLED)');

        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(BUYER), buyerBalBefore - AMOUNT + claimable, 'buyer net position');
    }

    /// @dev Open a single funded escrow; returns its workflow id (0 for the first).
    function _openFundedEscrow() internal returns (uint256 wf) {
        vm.prank(BUYER);
        wf = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'yield principal recorded');
    }

    /// @notice RELEASE path: sender releases the escrow, recipient receives principal + yield.
    function test_escrowLevel_release_distributesYieldToRecipient() public {
        uint256 wf = _openFundedEscrow();
        pool.simulateYield(address(token), 10);

        uint256 sellerBalBefore = token.balanceOf(SELLER);
        uint256 buyerBalBefore = token.balanceOf(BUYER);

        // Sender (buyer) releases the escrow to the recipient.
        vm.prank(BUYER);
        vault.release(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound on release');

        uint256 claimable = vault.claimableBalances(wf, SELLER);
        assertGt(claimable, AMOUNT, 'recipient claimable exceeds principal (yield)');

        vm.prank(SELLER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(SELLER), sellerBalBefore + claimable, 'recipient net position');
        // Sender's balance is unchanged by release (only principal was escrowed).
        assertEq(token.balanceOf(BUYER), buyerBalBefore, 'sender balance unchanged');
    }

    /// @notice SPLIT path: 50/50 split distributes yield pro-rata to both parties.
    function test_escrowLevel_split_distributesYieldProRata() public {
        uint256 wf = _openFundedEscrow();
        pool.simulateYield(address(token), 10);

        uint256 buyerBalBefore = token.balanceOf(BUYER);
        uint256 sellerBalBefore = token.balanceOf(SELLER);

        uint256 half = AMOUNT / 2;
        vm.prank(BUYER);
        vault.proposeSplit(wf, half, AMOUNT - half, 0);
        vm.prank(SELLER);
        vault.acceptSplit(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound on split');

        uint256 claimableBuyer = vault.claimableBalances(wf, BUYER);
        uint256 claimableSeller = vault.claimableBalances(wf, SELLER);
        assertGt(claimableBuyer, half, 'buyer gets principal half + yield share');
        assertGt(claimableSeller, AMOUNT - half, 'seller gets principal half + yield share');

        // Both parties pull their claimable amount.
        vm.prank(BUYER);
        uint256 gotBuyer = vault.withdrawEscrow(wf);
        vm.prank(SELLER);
        uint256 gotSeller = vault.withdrawEscrow(wf);
        assertEq(gotBuyer, claimableBuyer);
        assertEq(gotSeller, claimableSeller);
        assertEq(token.balanceOf(BUYER), buyerBalBefore + gotBuyer, 'buyer net position');
        assertEq(token.balanceOf(SELLER), sellerBalBefore + gotSeller, 'seller net position');
    }

    // ================= Time-based accrual E2E (realistic passage of time) =================
    // These drive yield by elapsed block.timestamp rather than discrete simulateYield
    // calls, exercising the full EscrowVault -> module -> pool flow with auto-accrual.

    /// @dev Constant matching the mock: timeYieldRate is scaled by 1e27.
    uint256 internal constant PER_SECOND_RATE = 1.9e19; // ~4.9% over 30 days
    uint256 internal constant ACCRUAL_WINDOW = 30 days;

    function _enableTimeAccrual() internal {
        pool.enableTimeAccrual(PER_SECOND_RATE);
    }

    function _expectedTimeYield(uint256 principal, uint256 elapsed) internal pure returns (uint256) {
        // index grows by base*rate*elapsed/1e27; base starts at 1e27 so yield = principal*rate*elapsed/1e27
        return (principal * PER_SECOND_RATE * elapsed) / 1e27;
    }

    /// @notice Realistic flow: deposit -> let 30 days of yield accrue -> mutually cancel ->
    ///         sender (ENABLED) receives principal + time-accrued yield -> withdraws.
    function test_escrowLevel_timeAccrual_cancel_yieldToSender() public {
        _enableTimeAccrual();
        uint256 wf = _openFundedEscrow();

        vm.warp(block.timestamp + ACCRUAL_WINDOW);

        uint256 expectedYield = _expectedTimeYield(AMOUNT, ACCRUAL_WINDOW);
        assertGt(expectedYield, 0, 'time yield is non-zero');

        // Preview before unwind reflects accrued value including yield.
        (uint256 pvPrincipal, uint256 pvValue, bool pvActive) = aaveModule.previewPosition(wf, address(vault));
        assertTrue(pvActive, 'position active before unwind');
        assertEq(pvPrincipal, AMOUNT, 'preview principal');
        assertGt(pvValue, AMOUNT, 'preview value exceeds principal (yield accrued)');

        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound');
        uint256 claimable = vault.claimableBalances(wf, BUYER);
        assertApproxEqAbs(claimable, AMOUNT + expectedYield, 2, 'sender claimable ~ principal + time yield');

        uint256 buyerBalBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(BUYER), buyerBalBefore + got, 'buyer net position');
    }

    /// @notice RELEASE path with time accrual: recipient receives principal + time-accrued yield
    ///         and actually withdraws it.
    function test_escrowLevel_timeAccrual_release_yieldToRecipient() public {
        _enableTimeAccrual();
        uint256 wf = _openFundedEscrow();

        vm.warp(block.timestamp + ACCRUAL_WINDOW);
        uint256 expectedYield = _expectedTimeYield(AMOUNT, ACCRUAL_WINDOW);

        vm.prank(BUYER);
        vault.release(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound on release');
        uint256 claimable = vault.claimableBalances(wf, SELLER);
        assertApproxEqAbs(claimable, AMOUNT + expectedYield, 2, 'recipient claimable ~ principal + time yield');

        uint256 sellerBalBefore = token.balanceOf(SELLER);
        vm.prank(SELLER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(SELLER), sellerBalBefore + got, 'recipient net position');
    }

    /// @notice SPLIT path with time accrual: yield split pro-rata to both parties.
    function test_escrowLevel_timeAccrual_split_proRata() public {
        _enableTimeAccrual();
        uint256 wf = _openFundedEscrow();

        vm.warp(block.timestamp + ACCRUAL_WINDOW);
        uint256 expectedYield = _expectedTimeYield(AMOUNT, ACCRUAL_WINDOW);

        uint256 half = AMOUNT / 2;
        vm.prank(BUYER);
        vault.proposeSplit(wf, half, AMOUNT - half, 0);
        vm.prank(SELLER);
        vault.acceptSplit(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound on split');

        uint256 claimableBuyer = vault.claimableBalances(wf, BUYER);
        uint256 claimableSeller = vault.claimableBalances(wf, SELLER);
        // Pro-rata: each gets its principal half plus half of the total time yield.
        assertApproxEqAbs(claimableBuyer, half + expectedYield / 2, 2, 'buyer pro-rata share');
        assertApproxEqAbs(claimableSeller, AMOUNT - half + (expectedYield - expectedYield / 2), 2, 'seller pro-rata share');

        uint256 gotBuyer;
        uint256 gotSeller;
        vm.prank(BUYER);
        gotBuyer = vault.withdrawEscrow(wf);
        vm.prank(SELLER);
        gotSeller = vault.withdrawEscrow(wf);
        assertEq(gotBuyer, claimableBuyer);
        assertEq(gotSeller, claimableSeller);
    }

    /// @notice Zero elapsed time produces no yield: guards the accrual boundary and ensures
    ///         the default index path returns exactly principal.
    function test_escrowLevel_timeAccrual_zeroElapsed_returnsPrincipal() public {
        _enableTimeAccrual();
        uint256 wf = _openFundedEscrow();

        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound');
        uint256 claimable = vault.claimableBalances(wf, BUYER);
        assertEq(claimable, AMOUNT, 'no yield without elapsed time');
    }

    /// @notice Real Aave module: dual unwind failure leaves escrow and position unsettled.
    ///         A recovery operator can later fund a keyed receipt, which only becomes a
    ///         beneficiary claim when settlement retries and consumes that receipt.
    function test_escrowLevel_aave_bothUnwindFail_recoveryReceiptFundsSettlementRetry() public {
        // Configure a non-zero protocol yield fee so the fee-exemption of the recovery path
        // is asserted meaningfully (not merely because the fee is off). The both-fail
        // settlement classifies zero yield, so no fee is ever charged.
        vault.setYieldProtocolFeeBps(1000);

        uint256 wf = _openFundedEscrow();
        assertEq(vault.v25YieldModules(wf), address(aaveModule), 'yield module recorded');

        // Accrue some yield so the recovered position is worth MORE than principal.
        pool.simulateYield(address(token), 10);

        // Record the live module state before the failure.
        (, uint256 pvValue, bool pvActive) = aaveModule.previewPosition(wf, address(vault));
        assertTrue(pvActive, 'module position active before failure');
        assertGt(pvValue, AMOUNT, 'module position value exceeds principal (yield accrued)');
        uint256 exposureBefore = aaveModule.totalDepositedByToken(address(token));
        assertEq(exposureBefore, AMOUNT, 'module exposure equals principal');

        // Break the pool's withdraw path. BOTH unwindToEscrow AND emergencyUnwind ultimately
        // call aavePool.withdraw, so both fail for the same reason (the shared-path finding).
        pool.setWithdrawFail(true);

        // The sender's consent is recorded. The recipient's finalizing call fails while
        // both unwind paths are unavailable, and the transaction rolls back.
        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vm.expectRevert();
        vault.recipientCancel(wf);

        assertEq(uint8(vault.getEscrowState(wf)), uint8(EscrowState.PENDING), 'failed unwind leaves escrow unsettled');
        assertEq(vault.v25YieldModules(wf), address(aaveModule), 'core yield linkage preserved');
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'core principal reference preserved');
        assertEq(vault.claimableBalances(wf, BUYER), 0, 'failed unwind creates no claim');
        assertEq(token.balanceOf(address(vault)), 0, 'vault unfunded after both-fail settle');

        // The module position and exposure survive both reverting unwind attempts.
        (, , bool activeAfterFail) = aaveModule.previewPosition(wf, address(vault));
        assertTrue(activeAfterFail, 'module position still live after failed unwind');
        assertEq(aaveModule.totalDepositedByToken(address(token)), exposureBefore, 'module exposure unchanged');
        assertGt(aToken.balanceOf(address(aaveModule)), 0, 'module holds aToken shares to recover');

        // Restore the pool and authorize an operator to unwind this position into the vault.
        // The operator's recovery receipt preserves the escrow/workflow association.
        pool.setWithdrawFail(false);
        address op = address(0xBEEF);
        aaveModule.setRecoveryOperator(op, true);

        uint256 vaultBalBefore = token.balanceOf(address(vault));
        vm.prank(op);
        uint256 recovered = aaveModule.emergencyUnwindForEscrow(
            address(vault), wf, address(token), AMOUNT
        );
        assertGt(recovered, AMOUNT, 'recovery returned principal + accrued yield');

        // The module position is now a funded, workflow-keyed recovery receipt.
        (, , bool activeAfterRecovery) = aaveModule.previewPosition(wf, address(vault));
        assertFalse(activeAfterRecovery, 'module position cleared after recovery');
        assertEq(aaveModule.totalDepositedByToken(address(token)), exposureBefore - AMOUNT, 'module exposure reduced');
        assertEq(token.balanceOf(address(vault)), vaultBalBefore + recovered, 'vault funded by recovery');

        (address receiptToken, uint256 receiptPrincipal, uint256 receiptRecovered) =
            aaveModule.recoveryReceipts(address(vault), wf);
        assertEq(receiptToken, address(token));
        assertEq(receiptPrincipal, AMOUNT);
        assertEq(receiptRecovered, recovered);
        assertEq(vault.v25YieldModules(wf), address(aaveModule), 'escrow link remains until settlement retry');
        assertEq(vault.claimableBalances(wf, BUYER), 0, 'receipt alone is not a claim');

        // Retry mutual settlement. The receipt is consumed exactly once and produces a
        // claim backed by the recovered vault balance.
        vm.prank(SELLER);
        vault.recipientCancel(wf);
        assertEq(uint8(vault.getEscrowState(wf)), uint8(EscrowState.REFUNDED));
        assertEq(vault.v25YieldModules(wf), address(0));
        assertEq(vault.claimableBalances(wf, BUYER), recovered);
        (receiptToken,, receiptRecovered) = aaveModule.recoveryReceipts(address(vault), wf);
        assertEq(receiptToken, address(0), 'receipt consumed');
        assertEq(receiptRecovered, 0, 'receipt cannot be reused');
        uint256 claimable = vault.claimableBalances(wf, BUYER);

        // Beneficiary withdraws exactly the (fee-exempt) entitlement, and it can't withdraw twice.
        uint256 buyerBalBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(BUYER), buyerBalBefore + got, 'buyer net position');
        assertEq(vault.claimableBalances(wf, BUYER), 0, 'no claimable remains after withdrawal');

        // Recovery is protocol-fee exempt even with a 1000 bps fee configured.
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'recovery path charges no protocol yield fee');
    }

    function test_operatorRecovery_partialLiquidityRevertsAndPreservesPosition() public {
        uint256 wf = _openFundedEscrow();
        address op = address(0xBEEF);
        aaveModule.setRecoveryOperator(op, true);

        uint256 sharesBefore = aToken.balanceOf(address(aaveModule));
        uint256 exposureBefore = aaveModule.totalDepositedByToken(address(token));
        uint256 poolBalanceBefore = token.balanceOf(address(pool));
        pool.setWithdrawCap(AMOUNT - 1);

        vm.prank(op);
        vm.expectRevert(bytes("PartialRecoveryNotAllowed"));
        aaveModule.emergencyUnwindForEscrow(address(vault), wf, address(token), AMOUNT);

        // The outer revert rolls back both Aave's partial withdrawal and the module's
        // position deletion. No partial receipt or escrow funding can be stranded.
        (, , bool active) = aaveModule.previewPosition(wf, address(vault));
        assertTrue(active, 'Aave position remains recoverable');
        assertEq(aToken.balanceOf(address(aaveModule)), sharesBefore, 'aToken shares restored');
        assertEq(aaveModule.totalDepositedByToken(address(token)), exposureBefore, 'exposure restored');
        assertEq(token.balanceOf(address(pool)), poolBalanceBefore, 'pool funds restored');
        (, , uint256 receiptAmount) = aaveModule.recoveryReceipts(address(vault), wf);
        assertEq(receiptAmount, 0, 'partial receipt not written');

        pool.setWithdrawCap(0);
        vm.prank(op);
        uint256 recovered = aaveModule.emergencyUnwindForEscrow(
            address(vault), wf, address(token), AMOUNT
        );
        assertGe(recovered, AMOUNT, 'full-principal recovery can be retried');
    }

    function test_recoveryReceipts_isolateEscrowsSharingVaultAndToken() public {
        uint256 first = _openFundedEscrow();
        uint256 second = _openFundedEscrow();
        assertEq(second, first + 1, 'fixture uses distinct workflow ids');

        pool.setWithdrawFail(true);
        for (uint256 wf = first; wf <= second; wf++) {
            vm.prank(BUYER);
            vault.senderCancel(wf);
            vm.prank(SELLER);
            vm.expectRevert();
            vault.recipientCancel(wf);
            assertEq(vault.v25YieldModules(wf), address(aaveModule), 'failed settlement keeps its own module link');
            assertEq(vault.claimableBalances(wf, BUYER), 0, 'failed settlement creates no claim');
        }

        pool.setWithdrawFail(false);
        address op = address(0xBEEF);
        aaveModule.setRecoveryOperator(op, true);
        vm.prank(op);
        uint256 recoveredFirst = aaveModule.emergencyUnwindForEscrow(
            address(vault), first, address(token), AMOUNT
        );

        (,, uint256 firstReceipt) = aaveModule.recoveryReceipts(address(vault), first);
        (,, uint256 secondReceipt) = aaveModule.recoveryReceipts(address(vault), second);
        assertEq(firstReceipt, recoveredFirst, 'recovery recorded for first workflow');
        assertEq(secondReceipt, 0, 'no receipt for second workflow');
        (, , bool firstActive) = aaveModule.previewPosition(first, address(vault));
        (, , bool secondActive) = aaveModule.previewPosition(second, address(vault));
        assertFalse(firstActive, 'first Aave position recovered');
        assertTrue(secondActive, 'second Aave position remains live');

        vm.prank(SELLER);
        vault.recipientCancel(first);
        assertEq(vault.claimableBalances(first, BUYER), recoveredFirst, 'first claim is backed by its recovery');
        assertEq(vault.claimableBalances(second, BUYER), 0, 'first recovery cannot fund second workflow');
        assertEq(vault.v25YieldModules(second), address(aaveModule), 'second workflow remains recoverable');

        // The second escrow can settle only after its own Aave position is unwound.
        vm.prank(SELLER);
        vault.recipientCancel(second);
        assertEq(vault.claimableBalances(second, BUYER), AMOUNT, 'second claim is backed by its own unwind');
        assertEq(vault.totalClaimableAssets(address(token)), recoveredFirst + AMOUNT);
        assertEq(token.balanceOf(address(vault)), recoveredFirst + AMOUNT, 'shared vault assets equal backed claims');
    }
}
