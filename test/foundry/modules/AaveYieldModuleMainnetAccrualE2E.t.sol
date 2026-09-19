// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/ops/YieldOps.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowCreationPolicy.sol';
import 'contracts/modules/DefaultReleaseStrategy.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/types/YieldPresets.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title AaveYieldModuleMainnetAccrualE2ETest
 * @notice Escrow-level END-TO-END against REAL Aave V3 on Base mainnet: deposit real USDC
 *         into an EscrowVault that is wired to the real AaveYieldModule, let real interest
 *         accrue in the Aave pool's liquidity index, then unwind and assert the sender
 *         (YieldPreset.TO_SENDER) can claim AND withdraw principal + realized yield.
 *
 *         This is a network-dependent test. It creates a fork of Base mainnet via
 *         vm.createSelectFork and pins to PINNED_BLOCK for deterministic CI. If the RPC is
 *         not configured (RPC_BASE_MAINNET missing) the suite skips gracefully.
 *
 * Run:
 *   forge test --match-contract AaveYieldModuleMainnetAccrualE2ETest -vvv
 *
 * Real Base mainnet addresses:
 *   Aave V3 Pool: 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
 *   USDC:         0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 *   aUSDC:        0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB
 *
 * @dev rationale for the explicit reserve refresh: Aave accrues interest lazily — the
 *      stored liquidity index only advances when the reserve is "touched" by an on-chain
 *      interaction. Pure vm.warp() advances block.timestamp but does not update the stored
 *      index. The module computes withdraw amount from getReserveNormalizedIncome, so we
 *      refresh the reserve (a 1-wei supply) AFTER warping so the index (and therefore the
 *      realized yield) is current before the unwind.
 */
contract AaveYieldModuleMainnetAccrualE2ETest is Test {
    // Base mainnet fork
    uint256 internal constant PINNED_BLOCK = 51500000;

    // Real Base mainnet Aave V3
    address internal constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    uint256 internal constant ACCRUAL_WINDOW = 20 days;

    EscrowVault internal vault;
    AaveYieldModule internal aaveModule;
    YieldOps internal yieldOps;
    ModuleSnapshotRegistry internal registry;
    EscrowCreationPolicy internal policy;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    uint256 internal constant AMOUNT = 5_000e6; // 5,000 USDC

    function setUp() public {
        string memory rpc = vm.envOr('RPC_BASE_MAINNET', string(''));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PINNED_BLOCK);

        if (AAVE_POOL.code.length == 0 || USDC.code.length == 0) {
            vm.skip(true);
            return;
        }

        aaveModule = new AaveYieldModule(AAVE_POOL);
        _cfgToken(USDC, AUSDC);

        yieldOps = new YieldOps(address(this));
        registry = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));

        vault = new EscrowVault(0, FEE, address(yieldOps), address(registry));
        _approve(address(vault));
        yieldOps.registerEscrowContract(address(vault));
        registry.registerEscrowContract(address(vault));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        // Give the full yield to the beneficiary (the sender) here; the dedicated protocol
        // fee math is exercised under this same canonical model in AaveYieldProtocolFee.
        vault.setYieldProtocolFeeBps(0);
        vault.setCreationPolicy(address(policy));

        registry.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        registry.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(new DefaultReleaseStrategy()));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        // Fund the buyer with real USDC on the fork.
        deal(USDC, BUYER, 1_000_000e6);
        vm.prank(BUYER);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }

    function _settings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
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

    /// @dev Real Aave accrues interest lazily. After warping time forward, touch the USDC
    ///      reserve (a real 10-USDC supply) so Aave recomputes the liquidity index past the
    ///      elapsed window. Without this, getReserveNormalizedIncome() still returns the stale
    ///      index and the module would only ever withdraw principal. A nominal 1-wei supply is
    ///      rejected by Aave (InvalidAmount) below the aToken rounding threshold, hence 10 USDC.
    function _refreshReserve() internal {
        uint256 refreshAmt = 10e6; // 10 USDC
        deal(USDC, address(this), refreshAmt);
        IERC20(USDC).approve(AAVE_POOL, type(uint256).max);
        IAavePool(AAVE_POOL).supply(USDC, refreshAmt, address(this), 0);
    }

    /// @dev Real end-to-end: deposit -> real yield accrues -> mutual cancel (TO_SENDER) ->
    ///      unwind against real Aave -> sender claims + withdraws principal + yield.
    function test_realAave_accrual_cancel_senderClaimsAndWithdraws() public {
        uint256 buyerBalBefore = IERC20(USDC).balanceOf(BUYER);

        vm.prank(BUYER);
        uint256 wf = vault.createEscrow(USDC, SELLER, AMOUNT, _settings());

        // Escrow pulled USDC from the buyer and forwarded it to the module -> Aave.
        assertEq(vault.v25YieldModules(wf), address(aaveModule), 'yield module recorded');
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'yield principal recorded');
        assertGt(IERC20(AUSDC).balanceOf(address(aaveModule)), 0, 'module holds aUSDC');
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, 'escrow forwarded full amount');

        // Let real Aave interest accrue, then refresh the reserve index so the module sees it.
        vm.warp(block.timestamp + ACCRUAL_WINDOW);
        _refreshReserve();

        // Preview before unwind reflects the accrued value (index-based).
        (uint256 pvPrincipal, uint256 pvValue, bool pvActive) = aaveModule.previewPosition(wf, address(vault));
        assertTrue(pvActive, 'position active');
        assertEq(pvPrincipal, AMOUNT, 'preview principal == deposited');
        assertGt(pvValue, AMOUNT, 'preview value exceeds principal (real yield accrued)');

        // Mutually cancel: sender (TO_SENDER) receives principal + yield.
        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound');
        uint256 claimable = vault.claimableBalances(wf, BUYER);
        assertGt(claimable, AMOUNT, 'sender claimable exceeds principal (real yield TO_SENDER)');
        // Realistic sanity bound: yield cannot be absurd (guard against index corruptions).
        assertLt(claimable, AMOUNT * 2, 'yield bounded');

        // The module should have withdrawn its full aUSDC position back.
        assertLe(IERC20(AUSDC).balanceOf(address(aaveModule)), 1, 'module aUSDC position fully withdrawn');

        // Sender actually pulls principal + yield.
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(IERC20(USDC).balanceOf(BUYER), buyerBalBefore - AMOUNT + claimable, 'buyer net position');
    }

    /// @dev RELEASE path against real Aave: recipient (seller) receives + withdraws yield.
    function test_realAave_accrual_release_recipientClaimsAndWithdraws() public {
        uint256 sellerBalBefore = IERC20(USDC).balanceOf(SELLER);

        vm.prank(BUYER);
        uint256 wf = vault.createEscrow(USDC, SELLER, AMOUNT, _settings());

        vm.warp(block.timestamp + ACCRUAL_WINDOW);
        _refreshReserve();

        vm.prank(BUYER);
        vault.release(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound on release');
        uint256 claimable = vault.claimableBalances(wf, SELLER);
        assertGt(claimable, AMOUNT, 'recipient claimable exceeds principal (yield)');

        vm.prank(SELLER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(IERC20(USDC).balanceOf(SELLER), sellerBalBefore + got, 'recipient net position');
    }
}
