// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowCreationPolicy.sol';
import 'contracts/modules/DefaultReleaseStrategy.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/types/YieldPresets.sol';
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
}
