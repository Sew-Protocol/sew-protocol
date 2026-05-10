// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowableERC20.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/core/EscrowableERC20.sol';

/**
 * @title EscrowableERC20CoverageTest
 * @notice Complete coverage for EscrowableERC20 — constructor, escrow lifecycle,
 *         fee management, onlyThisToken guard, factory, and accounting invariants.
 */
contract EscrowableERC20CoverageTest is Test {
    EscrowableERC20 public token;
    EscrowableERC20Factory public factory;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    DefaultReleaseStrategy public releaseStrategy;

    address public feeAddress = address(0xFEE);
    address public resolver   = address(0x1234);
    address public buyer      = address(0x1001);
    address public seller     = address(0x1002);

    uint256 constant FEE_BPS = 100;  // 1%
    uint256 constant AMOUNT  = 1000e18;

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _defaultSettings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    function _transferToBuyer(uint256 amount) internal {
        token.transfer(buyer, amount);
    }

    function _createEscrow(address from, uint256 amount) internal returns (uint256) {
        _transferToBuyer(amount);
        vm.prank(from);
        return token.createEscrow(seller, amount, 0, 0);
    }

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        yieldOps      = new YieldOps(address(this));
        disputeOps    = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps     = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        resolutionModule = new DefaultResolutionModule(address(this), resolver);
        releaseStrategy = new DefaultReleaseStrategy();

        token = new EscrowableERC20(
            'SEW Token', 'SEW', FEE_BPS, feeAddress,
            address(yieldOps), address(disputeOps), address(moduleManagement)
        );

        factory = new EscrowableERC20Factory();

        moduleManagement.registerEscrowContract(address(token));
        moduleManagement.queueModule(address(token), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(token), BaseEscrow.ModuleType.RELEASE);

        yieldOps.registerEscrowContract(address(token));
        disputeOps.registerEscrowContract(address(token));
        settlementOps.registerEscrowContract(address(token));
        createOps.registerEscrowContract(address(token));
        bondCollector.registerEscrowContract(address(token));

        token.grantRole(token.ROLE_ADMIN_CONTRACT(), address(this));
        token.setCreateOps(address(createOps));
        token.setSettlementOps(address(settlementOps));
        token.setBondCollector(address(bondCollector));
        token.setResolutionModule(address(resolutionModule));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Constructor validation
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_mints_initial_supply() public view {
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
        assertEq(token.balanceOf(address(this)), token.INITIAL_SUPPLY());
    }

    function test_constructor_sets_fee_and_address() public view {
        assertEq(token.escrowFee(), FEE_BPS);
        assertEq(token.escrowFeeAddress(), feeAddress);
    }

    function test_constructor_grants_roles_to_deployer() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(token.hasRole(token.ROLE_TIMELOCK(), address(this)));
    }

    function test_constructor_revert_fee_too_high() public {
        uint256 badFee = token.MAX_ESCROW_FEE_BPS() + 1;
        vm.expectRevert();
        new EscrowableERC20('T', 'T', badFee, feeAddress,
            address(yieldOps), address(disputeOps), address(moduleManagement));
    }

    function test_constructor_revert_zero_fee_address() public {
        vm.expectRevert();
        new EscrowableERC20('T', 'T', FEE_BPS, address(0),
            address(yieldOps), address(disputeOps), address(moduleManagement));
    }

    function test_constructor_revert_zero_yield_ops() public {
        vm.expectRevert();
        new EscrowableERC20('T', 'T', FEE_BPS, feeAddress,
            address(0), address(disputeOps), address(moduleManagement));
    }

    function test_constructor_revert_zero_dispute_ops() public {
        vm.expectRevert();
        new EscrowableERC20('T', 'T', FEE_BPS, feeAddress,
            address(yieldOps), address(0), address(moduleManagement));
    }

    function test_constructor_revert_zero_module_management() public {
        vm.expectRevert();
        new EscrowableERC20('T', 'T', FEE_BPS, feeAddress,
            address(yieldOps), address(disputeOps), address(0));
    }

    function test_constructor_revert_no_code_yield_ops() public {
        vm.expectRevert();
        new EscrowableERC20('T', 'T', FEE_BPS, feeAddress,
            address(0xAAAA), address(disputeOps), address(moduleManagement));
    }

    function test_constructor_revert_no_code_dispute_ops() public {
        vm.expectRevert();
        new EscrowableERC20('T', 'T', FEE_BPS, feeAddress,
            address(yieldOps), address(0xBBBB), address(moduleManagement));
    }

    function test_constructor_revert_no_code_module_management() public {
        vm.expectRevert();
        new EscrowableERC20('T', 'T', FEE_BPS, feeAddress,
            address(yieldOps), address(disputeOps), address(0xCCCC));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // createEscrow convenience function
    // ═══════════════════════════════════════════════════════════════════════════

    function test_createEscrow_simple_success() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        assertEq(id, 0);
    }

    function test_createEscrow_increments_workflowId() public {
        uint256 id0 = _createEscrow(buyer, AMOUNT);
        uint256 id1 = _createEscrow(buyer, AMOUNT);
        assertEq(id0, 0);
        assertEq(id1, 1);
    }

    function test_createEscrow_updates_totalHeldInEscrow() public {
        _createEscrow(buyer, AMOUNT);
        uint256 fee = AMOUNT * FEE_BPS / 10_000;
        assertEq(token.totalHeldInEscrow(), AMOUNT - fee);
    }

    function test_createEscrow_updates_totalFees() public {
        _createEscrow(buyer, AMOUNT);
        uint256 fee = AMOUNT * FEE_BPS / 10_000;
        assertEq(token.totalFees(), fee);
    }

    function test_createEscrow_full_settings_path() public {
        _transferToBuyer(AMOUNT);
        EscrowSettings memory settings = _defaultSettings();
        vm.prank(buyer);
        uint256 id = token.createEscrow(address(token), seller, AMOUNT, settings);
        assertEq(id, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // releaseEscrowTransfer
    // ═══════════════════════════════════════════════════════════════════════════

    function test_releaseEscrowTransfer_happy_path() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 sellerBefore = token.balanceOf(seller);
        vm.prank(buyer);
        token.release(id);
        assertEq(token.balanceOf(seller), sellerBefore);
        uint256 fee = AMOUNT * FEE_BPS / 10_000;
        assertEq(token.claimableBalances(id, seller), AMOUNT - fee);
    }

    function test_releaseEscrowTransfer_revert_non_sender() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        vm.expectRevert();
        vm.prank(seller);
        token.release(id);
    }

    function test_releaseEscrowTransfer_clears_totalHeld() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        vm.prank(buyer);
        token.release(id);
        assertEq(token.totalHeldInEscrow(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // withdrawFees
    // ═══════════════════════════════════════════════════════════════════════════

    function test_withdrawFees_transfers_to_fee_address() public {
        _createEscrow(buyer, AMOUNT);
        uint256 fee = AMOUNT * FEE_BPS / 10_000;
        uint256 before = token.balanceOf(feeAddress);
        vm.prank(feeAddress);
        token.withdrawFees();
        assertEq(token.balanceOf(feeAddress), before + fee);
    }

    function test_withdrawFees_clears_totalFees() public {
        _createEscrow(buyer, AMOUNT);
        vm.prank(feeAddress);
        token.withdrawFees();
        assertEq(token.totalFees(), 0);
    }

    function test_withdrawFees_emits_event() public {
        _createEscrow(buyer, AMOUNT);
        uint256 fee = AMOUNT * FEE_BPS / 10_000;
        vm.expectEmit(false, false, false, true, address(token));
        emit EscrowableERC20.FeesWithdrawn(fee);
        vm.prank(feeAddress);
        token.withdrawFees();
    }

    function test_withdrawFees_returns_true() public {
        _createEscrow(buyer, AMOUNT);
        vm.prank(feeAddress);
        bool ok = token.withdrawFees();
        assertTrue(ok);
    }

    function test_withdrawFees_revert_not_fee_address() public {
        _createEscrow(buyer, AMOUNT);
        vm.expectRevert(abi.encodeWithSignature(
            'NotFeeAddress(address,address)', buyer, feeAddress
        ));
        vm.prank(buyer);
        token.withdrawFees();
    }

    function test_withdrawFees_revert_zero_fees() public {
        vm.expectRevert(abi.encodeWithSignature(
            'NoFeesToWithdraw(address,uint256)', address(token), 0
        ));
        vm.prank(feeAddress);
        token.withdrawFees();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // onlyThisToken modifier — wrong token path
    // ═══════════════════════════════════════════════════════════════════════════

    function test_createEscrow_revert_wrong_token() public {
        // Passing a foreign token should revert via onlyThisToken in _pullTokens
        address foreignToken = address(0xDEAD);
        _transferToBuyer(AMOUNT);
        EscrowSettings memory settings = _defaultSettings();
        vm.prank(buyer);
        // BaseEscrow calls _pullTokens(token, from, amount) where token is the
        // foreign address — onlyThisToken fires before the transfer.
        vm.expectRevert();
        token.createEscrow(foreignToken, seller, AMOUNT, settings);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // _updateEscrowBalance underflow guard
    // ═══════════════════════════════════════════════════════════════════════════

    function test_balanceUnderflow_cannot_happen_via_normal_flow() public {
        // Normal release: balance was set during create, release decrements correctly.
        uint256 id = _createEscrow(buyer, AMOUNT);
        vm.prank(buyer);
        token.release(id);
        assertEq(token.totalHeldInEscrow(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Cancel paths
    // ═══════════════════════════════════════════════════════════════════════════

    function test_senderCancel_decrements_totalHeld() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        // Both parties must signal cancel — recipient first, then sender confirms.
        vm.prank(seller);
        token.recipientCancel(id);
        vm.prank(buyer);
        token.senderCancel(id);
        assertEq(token.totalHeldInEscrow(), 0);
    }

    function test_recipientCancel_decrements_totalHeld() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        vm.prank(seller);
        token.recipientCancel(id);
        vm.prank(buyer);
        token.senderCancel(id);
        assertEq(token.totalHeldInEscrow(), 0);
    }

    function test_senderCancel_refunds_buyer() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        // After create, buyer has 0 (all AMOUNT sent to escrow)
        assertEq(token.balanceOf(buyer), 0);

        // Mutual cancel — buyer gets principal (minus fee) back
        vm.prank(seller);
        token.recipientCancel(id);
        vm.prank(buyer);
        token.senderCancel(id);

        uint256 fee = AMOUNT * FEE_BPS / 10_000;
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.claimableBalances(id, buyer), AMOUNT - fee);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Multi-escrow accounting integrity
    // ═══════════════════════════════════════════════════════════════════════════

    function test_multiple_escrows_aggregate_totalHeld() public {
        _createEscrow(buyer, AMOUNT);
        _createEscrow(buyer, AMOUNT);
        uint256 fee = AMOUNT * FEE_BPS / 10_000;
        assertEq(token.totalHeldInEscrow(), (AMOUNT - fee) * 2);
    }

    function test_multiple_escrows_aggregate_totalFees() public {
        _createEscrow(buyer, AMOUNT);
        _createEscrow(buyer, AMOUNT);
        uint256 fee = AMOUNT * FEE_BPS / 10_000;
        assertEq(token.totalFees(), fee * 2);
    }

    function test_mixed_release_and_cancel_accounting() public {
        uint256 id0 = _createEscrow(buyer, AMOUNT);
        uint256 id1 = _createEscrow(buyer, AMOUNT);
        uint256 fee = AMOUNT * FEE_BPS / 10_000;

        vm.prank(buyer);
        token.release(id0);
        assertEq(token.totalHeldInEscrow(), AMOUNT - fee);

        // Mutual cancel for id1
        vm.prank(seller);
        token.recipientCancel(id1);
        vm.prank(buyer);
        token.senderCancel(id1);
        assertEq(token.totalHeldInEscrow(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EscrowableERC20Factory
    // ═══════════════════════════════════════════════════════════════════════════

    function test_factory_creates_valid_token() public {
        address newToken = factory.createEscrowableERC20(
            'Factory Token', 'FTK', FEE_BPS, feeAddress,
            address(yieldOps), address(disputeOps), address(moduleManagement)
        );
        assertNotEq(newToken, address(0));
        assertGt(newToken.code.length, 0);
    }

    function test_factory_token_has_initial_supply() public {
        address newToken = factory.createEscrowableERC20(
            'Factory Token', 'FTK', FEE_BPS, feeAddress,
            address(yieldOps), address(disputeOps), address(moduleManagement)
        );
        EscrowableERC20 t = EscrowableERC20(newToken);
        assertEq(t.totalSupply(), t.INITIAL_SUPPLY());
    }

    function test_factory_mints_supply_to_caller() public {
        vm.prank(buyer);
        address newToken = factory.createEscrowableERC20(
            'Factory Token', 'FTK', FEE_BPS, feeAddress,
            address(yieldOps), address(disputeOps), address(moduleManagement)
        );
        EscrowableERC20 t = EscrowableERC20(newToken);
        // _mint targets _msgSender() inside constructor, which is the factory contract itself
        assertEq(t.balanceOf(address(factory)), t.INITIAL_SUPPLY());
    }

    function test_factory_revert_invalid_params() public {
        vm.expectRevert();
        factory.createEscrowableERC20(
            'T', 'T', FEE_BPS, address(0),  // zero fee address
            address(yieldOps), address(disputeOps), address(moduleManagement)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // moduleManagement immutable
    // ═══════════════════════════════════════════════════════════════════════════

    function test_moduleManagement_set_correctly() public view {
        assertEq(address(token.moduleManagement()), address(moduleManagement));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Zero-fee constructor path
    // ═══════════════════════════════════════════════════════════════════════════

    function test_zero_fee_escrow() public {
        EscrowableERC20 zeroFeeToken = new EscrowableERC20(
            'Zero Fee', 'ZF', 0, feeAddress,
            address(yieldOps), address(disputeOps), address(moduleManagement)
        );
        moduleManagement.registerEscrowContract(address(zeroFeeToken));
        moduleManagement.queueModule(address(zeroFeeToken), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(zeroFeeToken), BaseEscrow.ModuleType.RELEASE);

        yieldOps.registerEscrowContract(address(zeroFeeToken));
        disputeOps.registerEscrowContract(address(zeroFeeToken));
        createOps.registerEscrowContract(address(zeroFeeToken));
        settlementOps.registerEscrowContract(address(zeroFeeToken));
        bondCollector.registerEscrowContract(address(zeroFeeToken));

        zeroFeeToken.grantRole(zeroFeeToken.ROLE_ADMIN_CONTRACT(), address(this));
        zeroFeeToken.setCreateOps(address(createOps));
        zeroFeeToken.setSettlementOps(address(settlementOps));
        zeroFeeToken.setBondCollector(address(bondCollector));
        zeroFeeToken.setResolutionModule(address(resolutionModule));

        address buyer2 = address(0x9999);
        zeroFeeToken.transfer(buyer2, AMOUNT);
        vm.prank(buyer2);
        uint256 id = zeroFeeToken.createEscrow(seller, AMOUNT, 0, 0);
        assertEq(zeroFeeToken.totalFees(), 0);
        assertEq(zeroFeeToken.totalHeldInEscrow(), AMOUNT);

        vm.prank(buyer2);
        zeroFeeToken.release(id);
        assertEq(zeroFeeToken.totalHeldInEscrow(), 0);
    }
}
