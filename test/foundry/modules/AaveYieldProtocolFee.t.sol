// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowCreationPolicy.sol';
import 'contracts/modules/DefaultReleaseStrategy.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/interfaces/IYieldModule.sol';
import 'contracts/types/YieldPresets.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/// @notice Deterministic yield module used to exercise the protocol yield fee at the
///         EscrowVault settlement layer. The escrow pulls principal into this mock on
///         initializeYield; unwindToEscrow returns a caller-configurable (principal, yield)
///         and physically transfers principal + yield back to the escrow so balance
///         accounting stays exact.
contract MockYieldModuleFee is IYieldModule {
    using SafeERC20 for IERC20;

    struct Pos {
        address token;
        uint256 principal;
    }
    mapping(address escrow => mapping(uint256 escrowId => Pos)) private pos;

    uint256 public yieldOut;
    uint256 public loss;

    function setYield(uint256 y) external { yieldOut = y; }
    function setLoss(uint256 l) external { loss = l; }

    function initializeYield(uint256 escrowId, address token, uint256 amount, YieldPreset yieldMode)
        external returns (uint256) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        pos[msg.sender][escrowId] = Pos(token, amount);
        emit YieldInitialized(escrowId, token, amount, yieldMode);
        return amount;
    }

    function unwindToEscrow(uint256 escrowId, address token, uint256)
        external returns (uint256 principal, uint256 yield_) {
        Pos memory p = pos[msg.sender][escrowId];
        delete pos[msg.sender][escrowId];
        principal = p.principal > loss ? p.principal - loss : 0;
        yield_ = yieldOut;
        uint256 total = principal + yield_;
        if (total > 0) IERC20(token).safeTransfer(msg.sender, total);
        emit YieldWithdrawn(escrowId, token, principal, yield_);
        return (principal, yield_);
    }

    function emergencyUnwind(uint256 escrowId, address token, uint256)
        external returns (uint256 recovered) {
        Pos memory p = pos[msg.sender][escrowId];
        delete pos[msg.sender][escrowId];
        recovered = p.principal > loss ? p.principal - loss : 0;
        if (recovered > 0) IERC20(token).safeTransfer(msg.sender, recovered);
        emit EmergencyUnwindExecuted(escrowId, token, recovered, keccak256('emergency_unwind'));
        return recovered;
    }

    function canHandle(address, YieldPreset, uint256) external pure returns (bool, bytes32) {
        return (true, 0x0);
    }
    function previewPosition(uint256, address) external pure returns (uint256, uint256, bool) {
        return (0, 0, false);
    }
    function getModuleInfo() external pure returns (string memory, string memory, bytes32) {
        return ('MockYieldModuleFee', '1.0.0', keccak256('mock-fee'));
    }
}

/**
 * @title AaveYieldProtocolFeeTest
 * @notice Adversarial coverage for the protocol yield fee realized at settlement.
 *         Economic model exercised here:
 *           P = principal, R = assets recovered, Y = max(R - P, 0)
 *           F = floor(Y * feeBps / 10_000), B = Y - F
 *           conservation: R = P + B + F  (only F is floored)
 *         - fee is never charged against principal / never on losses
 *         - fee is credited to the pull-based totalFeesPerToken bucket (withdrawable via
 *           withdrawFees), not paid out during settlement
 *         - the snapshotted fee rate at escrow creation governs, not the current rate
 */
contract AaveYieldProtocolFeeTest is Test {
    EscrowVault internal vault;
    MockYieldModuleFee internal module;
    ModuleSnapshotRegistry internal registry;
    EscrowCreationPolicy internal policy;
    ERC20Mock internal token;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    uint256 internal constant AMOUNT = 1000e18;
    uint256 internal constant DEFAULT_FEE_BPS = 3000; // matches DEFAULT_YIELD_PROTOCOL_FEE_BPS

    function setUp() public {
        token = new ERC20Mock('Token', 'TKN', address(this), 0);
        module = new MockYieldModuleFee();
        registry = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));

        vault = new EscrowVault(0, FEE, address(registry));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreationPolicy(address(policy));

        registry.registerEscrowContract(address(vault));

        registry.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(module));
        registry.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(new DefaultReleaseStrategy()));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        token.mint(BUYER, 1_000_000e18);
        // Fund the yield mock so it can pay out positive yield (principal + yield).
        token.mint(address(module), 1_000_000e18);
    }

    function _setFee(uint256 bps) internal {
        vault.setYieldProtocolFeeBps(bps);
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

    // Open a funded escrow buyer -> seller with yield enabled, fee rate already snapshotted.
    function _openEscrow() internal returns (uint256 wf) {
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BUYER);
        wf = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'yield principal recorded');
    }

    // Release buyer -> seller; seller receives principal + (yield - fee).
    function _release(uint256 wf) internal {
        vm.prank(BUYER);
        vault.release(wf);
        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound on release');
    }

    // ================= Zero yield =================

    function test_zeroYield_noFee_returnsPrincipal() public {
        _setFee(DEFAULT_FEE_BPS);
        uint256 wf = _openEscrow();
        module.setYield(0);

        _release(wf);
        assertEq(vault.claimableBalances(wf, SELLER), AMOUNT, 'no yield -> full principal claimable');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'no yield -> no protocol fee');
    }

    // ================= Positive yield =================

    function test_positiveYield_feeCharged_conservation() public {
        _setFee(DEFAULT_FEE_BPS); // 30%
        uint256 wf = _openEscrow();
        uint256 yieldAmt = 100e18;
        module.setYield(yieldAmt);

        _release(wf);

        uint256 expectedFee = yieldAmt * DEFAULT_FEE_BPS / 10_000; // 30e18
        uint256 expectedBeneficiary = AMOUNT + (yieldAmt - expectedFee);
        assertEq(vault.claimableBalances(wf, SELLER), expectedBeneficiary, 'beneficiary = P + (Y - F)');
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee, 'protocol fee credited to fee bucket');
        // Conservation: R = P + B + F
        assertEq(
            vault.claimableBalances(wf, SELLER) + vault.totalFeesPerToken(address(token)),
            AMOUNT + yieldAmt,
            'conservation R = P + B + F'
        );
    }

    // ================= R < P (loss) =================

    function test_loss_RlessThanP_feeZero_neverConsumesPrincipal() public {
        _setFee(DEFAULT_FEE_BPS);
        uint256 wf = _openEscrow();
        uint256 lossAmt = 100e18;
        module.setLoss(lossAmt);
        module.setYield(0);

        _release(wf);

        // Recovered principal = AMOUNT - loss. Loss is not a fee obligation.
        assertEq(vault.claimableBalances(wf, SELLER), AMOUNT - lossAmt, 'only recovered principal claimable');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'loss yields ZERO protocol fee');
        // Recovered assets conservation with no yield: beneficiary claim == recovered principal.
        assertEq(vault.totalFeesPerToken(address(token)) + vault.claimableBalances(wf, SELLER), AMOUNT - lossAmt);
    }

    // ================= R == P =================

    function test_R_equalP_feeZero() public {
        _setFee(DEFAULT_FEE_BPS);
        uint256 wf = _openEscrow();
        // No loss, no yield -> R == P.
        _release(wf);
        assertEq(vault.claimableBalances(wf, SELLER), AMOUNT, 'R == P -> exactly principal');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'R == P -> no fee');
    }

    // ================= Rounding / dust =================

    function test_rounding_dust_yield_below_one_bps_of_fee() public {
        _setFee(DEFAULT_FEE_BPS);
        uint256 wf = _openEscrow();
        // yield = 1 wei; F = floor(1*3000/10000) = 0.
        module.setYield(1);

        _release(wf);
        // All dust yield flows to beneficiary; no fee on sub-unit rounding.
        assertEq(vault.claimableBalances(wf, SELLER), AMOUNT + 1, 'dust yield fully to beneficiary');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'floor rounding -> zero fee');
        assertEq(vault.claimableBalances(wf, SELLER) + vault.totalFeesPerToken(address(token)), AMOUNT + 1, 'conservation');
    }

    // ================= Max fee rate =================

    function test_maxFeeRate_30percent() public {
        _setFee(3000); // MAX_PROTOCOL_FEE_BPS
        uint256 wf = _openEscrow();
        uint256 yieldAmt = 200e18;
        module.setYield(yieldAmt);

        _release(wf);
        uint256 expectedFee = yieldAmt * 3000 / 10_000; // 60e18
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee, 'max fee = 30% of yield');
        assertEq(vault.claimableBalances(wf, SELLER), AMOUNT + (yieldAmt - expectedFee));
        assertEq(vault.claimableBalances(wf, SELLER) + vault.totalFeesPerToken(address(token)), AMOUNT + yieldAmt, 'conservation');
    }

    // ================= Zero fee rate =================

    function test_zeroFeeRate_fullYieldToBeneficiary() public {
        _setFee(0);
        uint256 wf = _openEscrow();
        uint256 yieldAmt = 100e18;
        module.setYield(yieldAmt);

        _release(wf);
        assertEq(vault.claimableBalances(wf, SELLER), AMOUNT + yieldAmt, 'zero fee -> full yield to beneficiary');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'zero fee -> no protocol fee');
    }

    // ================= Fee snapshot unaffected by later config change =================

    function test_feeSnapshot_isPerEscrow_notAffectedByLaterChange() public {
        // Escrow1 is created while the fee is 30% -> snapshots 30%.
        _setFee(DEFAULT_FEE_BPS);
        uint256 wf1 = _openEscrow();

        // Governance lowers the global rate to 0 BEFORE escrow2 is created.
        _setFee(0);
        uint256 wf2 = _openEscrow();

        uint256 yield1 = 100e18;
        uint256 yield2 = 100e18;
        module.setYield(yield1);
        _release(wf1);
        // The 30% snapshot on wf1 still applies (30e18 fee).
        assertEq(vault.totalFeesPerToken(address(token)), yield1 * DEFAULT_FEE_BPS / 10_000, 'wf1 uses its 30% snapshot');

        uint256 feesBefore = vault.totalFeesPerToken(address(token));
        module.setYield(yield2);
        _release(wf2);
        // wf2 was created under the 0% rate -> no additional fee.
        assertEq(vault.totalFeesPerToken(address(token)), feesBefore, 'wf2 created at 0% -> no fee');
        assertEq(vault.claimableBalances(wf2, SELLER), AMOUNT + yield2, 'wf2 full yield to beneficiary');
    }

    // ================= No double charge on repeated execution paths =================

    function test_yield_chargedExactlyOnce() public {
        _setFee(DEFAULT_FEE_BPS);
        uint256 wf = _openEscrow();
        module.setYield(100e18);

        _release(wf);
        // The single unwind produced exactly one fee (position + module linkage cleared).
        assertEq(vault.totalFeesPerToken(address(token)), 100e18 * DEFAULT_FEE_BPS / 10_000);

        // The position is gone; a re-entrant/second settlement cannot charge again
        // (state is RESOLVED and v25YieldModules cleared).
        assertEq(vault.v25YieldModules(wf), address(0));
        vm.prank(SELLER);
        vault.withdrawEscrow(wf);
        assertEq(vault.totalFeesPerToken(address(token)), 100e18 * DEFAULT_FEE_BPS / 10_000, 'fee unchanged after withdraw');
    }

    // ================= Split path applies the fee once, then splits remainder =================

    function test_splitPath_feeAppliedOnce_thenDivided() public {
        _setFee(DEFAULT_FEE_BPS);
        uint256 wf = _openEscrow();
        uint256 yieldAmt = 100e18;
        module.setYield(yieldAmt);

        uint256 half = AMOUNT / 2;
        vm.prank(BUYER);
        vault.proposeSplit(wf, half, AMOUNT - half, 0);
        vm.prank(SELLER);
        vault.acceptSplit(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound on split');

        uint256 expectedFee = yieldAmt * DEFAULT_FEE_BPS / 10_000; // 30e18
        uint256 yieldAfterFee = yieldAmt - expectedFee;            // 70e18
        uint256 yieldShare = yieldAfterFee / 2;                    // 35e18 each (pro-rata half)
        assertEq(vault.claimableBalances(wf, BUYER), half + yieldShare, 'buyer principal + net yield share');
        assertEq(vault.claimableBalances(wf, SELLER), (AMOUNT - half) + (yieldAfterFee - yieldShare), 'seller principal + net yield share');
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee, 'fee charged once on split');

        // Conservation across both beneficiaries + fee.
        assertEq(
            vault.claimableBalances(wf, BUYER) + vault.claimableBalances(wf, SELLER) + vault.totalFeesPerToken(address(token)),
            AMOUNT + yieldAmt,
            'split conservation R = P + B + F'
        );
    }

    // ================= Fee is pull-based (not paid during settlement) =================

    function test_fee_isPullBased_notTransferredOnSettlement() public {
        _setFee(DEFAULT_FEE_BPS);
        uint256 wf = _openEscrow();
        module.setYield(100e18);

        uint256 feeWalletBefore = token.balanceOf(FEE);
        _release(wf);

        // Fee is credited to the pull-based bucket; the fee wallet is untouched
        // until withdrawFees() is called by a ROLE_FEE_RECIPIENT.
        assertEq(token.balanceOf(FEE), feeWalletBefore, 'fee wallet unchanged at settlement');
        assertGt(vault.totalFeesPerToken(address(token)), 0, 'fee recorded internally');
    }
}
