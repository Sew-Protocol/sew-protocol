// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import '../../../packages/sew-core/contracts/core/BaseEscrow.sol';
import '../../../packages/sew-core/contracts/core/ModuleSnapshotRegistry.sol';
import '../../../packages/sew-core/contracts/core/EscrowYield.sol';
import '../../../packages/sew-core/contracts/core/EscrowCreationPolicy.sol';
import '../../../packages/sew-core/contracts/modules/DefaultReleaseStrategy.sol';
import '../../../packages/sew-core/contracts/types/EscrowTypes.sol';
import '../../../packages/sew-core/contracts/types/YieldPresets.sol';
import 'contracts/mocks/ERC20Mock.sol';
import '../../../packages/sew-core/contracts/interfaces/IYieldModule.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/// @notice Deterministic yield module that forces the tail of
///         EscrowYield._handleYieldModuleUnwind where BOTH unwind paths fail:
///         unwindToEscrow always reverts and emergencyUnwind behavior is
///         configurable:
///           - revert            -> reaches the YieldUnwindFailed branch
///           - return < principal -> triggers the PartialRecoveryNotAllowed guard
contract YieldUnwindFailedModule is IYieldModule {
    using SafeERC20 for IERC20;

    struct Pos {
        address token;
        uint256 principal;
    }
    mapping(address escrow => mapping(uint256 escrowId => Pos)) private pos;

    // true  -> emergencyUnwind reverts (both paths fail)
    // false -> emergencyUnwind returns recoverAmount (may be partial)
    bool public emergencyReverts;
    // Amount returned by emergencyUnwind when emergencyReverts == false. EXPLICIT — 0 means
    // return 0 (a successful return that correctly hits the < principal guard when principal
    // is non-zero, and is semantically distinct from an emergency call that reverts). There is
    // NO sentinel: a test wanting full principal sets this to `principal`.
    uint256 public recoverAmount;

    function setEmergencyReverts(bool b) external { emergencyReverts = b; }
    function setRecoverAmount(uint256 a) external { recoverAmount = a; }

    function initializeYield(uint256 escrowId, address token, uint256 amount, YieldPreset yieldMode)
        external returns (uint256) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        pos[msg.sender][escrowId] = Pos(token, amount);
        emit YieldInitialized(escrowId, token, amount, yieldMode);
        return amount;
    }

    // Force the normal-unwind path to fail so EscrowYield tries emergencyUnwind.
    function unwindToEscrow(uint256, address, uint256) external pure returns (uint256, uint256) {
        revert('mock: normal unwind unavailable');
    }

    function emergencyUnwind(uint256 escrowId, address token, uint256)
        external returns (uint256 recovered) {
        if (emergencyReverts) revert('mock: emergency unwind unavailable');
        // Pos is deleted; no need to read it since the return amount is configurable.
        delete pos[msg.sender][escrowId];
        // Explicit return — no sentinel. 0 is a real (rejected) return, not "full principal".
        recovered = recoverAmount;
        // Transfer whatever was recovered back to the escrow.
        if (recovered > 0) IERC20(token).safeTransfer(msg.sender, recovered);
        emit EmergencyUnwindExecuted(escrowId, token, recovered, keccak256('yield_unwind_failed'));
        return recovered;
    }

    function canHandle(address, YieldPreset, uint256) external pure returns (bool, bytes32) {
        return (true, 0x0);
    }
    function previewPosition(uint256, address) external pure returns (uint256, uint256, bool) {
        return (0, 0, false);
    }
    function getModuleInfo() external pure returns (string memory, string memory, bytes32) {
        return ('YieldUnwindFailedModule', '1.0.0', keccak256('mock-unwind-failed'));
    }
}

/**
 * @title YieldUnwindFailedE2ETest
 * @notice Escrow-level end-to-end tests for the tail branches of
 *         EscrowYield._handleYieldModuleUnwind:
 *
 *           1. unwindToEscrow and emergencyUnwind both revert -> settlement reverts,
 *              preserving the escrow's module linkage and recovery identity until a
 *              later retry can actually recover the position.
 *           2. unwindToEscrow reverts and emergencyUnwind returns recovered < principal
 *              -> core reverts PartialRecoveryNotAllowed; the whole tx rolls back
 *              atomically (module token transfer + pos deletion included) and the
 *              position remains recoverable via a subsequent full-recovery retry.
 */
contract YieldUnwindFailedE2ETest is Test {
    EscrowVault internal vault;
    YieldUnwindFailedModule internal module;
    ModuleSnapshotRegistry internal registry;
    EscrowCreationPolicy internal policy;
    ERC20Mock internal token;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    uint256 internal constant AMOUNT = 1_000e18;
    uint256 internal constant YIELD = 123e18;



    function setUp() public {
        token = new ERC20Mock('Token', 'TKN', address(this), 0);
        module = new YieldUnwindFailedModule();
        registry = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));

        vault = new EscrowVault(0, FEE, address(registry));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setYieldProtocolFeeBps(0);
        vault.setCreationPolicy(address(policy));

        registry.registerEscrowContract(address(vault));

        registry.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(module));
        registry.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(new DefaultReleaseStrategy()));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        token.mint(BUYER, 1_000_000e18);
        // Extra headroom so a P+Y emergency return can be funded above the deposited
        // principal without minting mid-test. Keep this — P+Y tests rely on it.
        token.mint(address(module), 1_000_000e18);
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

    function _openEscrow() internal returns (uint256 wf) {
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BUYER);
        wf = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'yield principal recorded');
        // Principal now lives in the module, not the escrow.
        assertEq(token.balanceOf(address(vault)), 0, 'escrow emptied by yield deposit');
    }

    /// @dev If both unwind paths fail, settlement must preserve the position identity and
    ///      create no claim. Once the module can recover the full position, retry the action.
    function _runBothFail_preservesPosition_thenRetry(bool release) internal {
        uint256 wf = _openEscrow();
        module.setEmergencyReverts(true);
        address beneficiary = release ? SELLER : BUYER;
        uint256 beneficiaryBalanceBefore = token.balanceOf(beneficiary);

        if (release) {
            vm.prank(BUYER);
            vm.expectRevert(abi.encodeWithSelector(
                YieldUnwindUnavailable.selector, wf, address(token), address(module), AMOUNT
            ));
            vault.release(wf);
        } else {
            vm.prank(BUYER);
            vault.senderCancel(wf);
            vm.prank(SELLER);
            vm.expectRevert(abi.encodeWithSelector(
                YieldUnwindUnavailable.selector, wf, address(token), address(module), AMOUNT
            ));
            vault.recipientCancel(wf);
        }

        assertEq(vault.v25YieldModules(wf), address(module), 'module linkage preserved');
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'principal reference preserved');
        assertEq(vault.claimableBalances(wf, beneficiary), 0, 'no unfunded claim created');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'no fee on failed recovery');
        assertEq(token.balanceOf(address(vault)), 0, 'vault remains unfunded');

        module.setEmergencyReverts(false);
        module.setRecoverAmount(AMOUNT);
        if (release) {
            vm.prank(BUYER);
            vault.release(wf);
        } else {
            vm.prank(SELLER);
            vault.recipientCancel(wf);
        }

        assertEq(vault.v25YieldModules(wf), address(0), 'linkage cleared only after recovery');
        assertEq(vault.v25YieldPrincipals(wf), 0, 'position cleared only after recovery');
        assertEq(vault.claimableBalances(wf, beneficiary), AMOUNT, 'claim equals recovered principal');
        assertEq(token.balanceOf(address(vault)), AMOUNT, 'recovered principal is in vault');
        vm.prank(beneficiary);
        assertEq(vault.withdrawEscrow(wf), AMOUNT);
        assertEq(token.balanceOf(beneficiary), beneficiaryBalanceBefore + AMOUNT);
    }

    function test_bothPathsFail_preservesPosition_andCanRetryCancelAfterRecovery() public {
        _runBothFail_preservesPosition_thenRetry(false);
    }

    function test_bothPathsFail_preservesPosition_andCanRetryReleaseAfterRecovery() public {
        _runBothFail_preservesPosition_thenRetry(true);
    }

    /// @notice emergencyUnwind returns less than the deposited principal. Core reverts
    ///         PartialRecoveryNotAllowed and the WHOLE transaction (including the module's
    ///         pos deletion and partial token transfer) rolls back atomically; the position
    ///         remains recoverable, and a subsequent full-recovery retry succeeds.
    function test_partialRecovery_reverts_thenFullRecoveryRetrySucceeds() public {
        uint256 wf = _openEscrow();
        module.setEmergencyReverts(false);

        uint256 moduleBalBefore = token.balanceOf(address(module));
        uint256 vaultBalBefore = token.balanceOf(address(vault));

        // Partial recovery: emergency returns AMOUNT - 1.
        module.setRecoverAmount(AMOUNT - 1);
        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vm.expectRevert(PartialRecoveryNotAllowed.selector);
        vault.recipientCancel(wf);

        // Atomicity: the module's partial transfer AND delete pos were rolled back too.
        assertEq(token.balanceOf(address(module)), moduleBalBefore, 'module balance unchanged after revert');
        assertEq(token.balanceOf(address(vault)), vaultBalBefore, 'vault balance unchanged after revert');

        // Position/linkage/claimable/state all preserved.
        assertEq(vault.v25YieldModules(wf), address(module), 'linkage preserved on guard revert');
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'principal reference preserved');
        assertEq(vault.claimableBalances(wf, BUYER), 0, 'no claimable credited on guard revert');
        assertEq(
            uint8(vault.getEscrowState(wf)),
            uint8(EscrowState.PENDING),
            'escrow remains PENDING on guard revert'
        );

        // Configure full recovery and retry the SAME terminal op.
        module.setRecoverAmount(AMOUNT);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'linkage cleared on full recovery');
        assertEq(vault.v25YieldPrincipals(wf), 0, 'principal reference cleared');
        assertEq(
            uint8(vault.getEscrowState(wf)),
            uint8(EscrowState.REFUNDED),
            'escrow REFUNDED on full recovery'
        );
        assertEq(vault.claimableBalances(wf, BUYER), AMOUNT, 'beneficiary claimable = recovered principal');

        uint256 buyerBalBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, AMOUNT, 'withdrawn equals recovered principal');
        assertEq(token.balanceOf(BUYER), buyerBalBefore + got, 'buyer net position');
        assertEq(vault.claimableBalances(wf, BUYER), 0, 'no claimable remains after withdrawal');
    }

    /// @notice emergencyUnwind returning exactly the principal is accepted (baseline guard
    ///         passes) — sanity against the PartialRecoveryNotAllowed boundary.
    function test_partialRecovery_boundary_exactPrincipalAccepted() public {
        uint256 wf = _openEscrow();
        module.setEmergencyReverts(false);
        module.setRecoverAmount(AMOUNT);

        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'module linkage cleared on exact recovery');
        assertEq(vault.v25YieldPrincipals(wf), 0, 'principal reference cleared');
        assertEq(
            uint8(vault.getEscrowState(wf)),
            uint8(EscrowState.REFUNDED),
            'escrow REFUNDED on exact recovery'
        );
        assertEq(vault.claimableBalances(wf, BUYER), AMOUNT, 'sender claimable = recovered principal');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'no fee on exact principal recovery');

        uint256 buyerBalBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, AMOUNT, 'withdrawn equals recovered principal');
        assertEq(token.balanceOf(BUYER), buyerBalBefore + got, 'buyer net position');
        assertEq(vault.claimableBalances(wf, BUYER), 0, 'no claimable remains after withdrawal');
    }

    /// @notice emergencyUnwind returns MORE than principal (principal + yield). The success
    ///         path returns the whole recovered amount as principal with yieldOut = 0, so the
    ///         beneficiary receives exactly P + Y and NO protocol fee is charged. This is
    ///         intended: emergency recovery restores the beneficiary's full position.
    function test_emergencyUnwind_returnsPrincipalPlusYield() public {
        uint256 wf = _openEscrow();
        module.setEmergencyReverts(false);
        module.setRecoverAmount(AMOUNT + YIELD);

        uint256 moduleBalBefore = token.balanceOf(address(module));

        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(token.balanceOf(address(module)), moduleBalBefore - (AMOUNT + YIELD), 'module paid out P+Y');
        assertEq(vault.v25YieldModules(wf), address(0), 'module linkage cleared');
        assertEq(vault.v25YieldPrincipals(wf), 0, 'principal reference cleared');
        assertEq(
            uint8(vault.getEscrowState(wf)),
            uint8(EscrowState.REFUNDED),
            'escrow REFUNDED'
        );
        assertEq(vault.claimableBalances(wf, BUYER), AMOUNT + YIELD, 'beneficiary gets P+Y');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'emergency recovery charges no yield fee');

        uint256 buyerBalBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, AMOUNT + YIELD, 'withdrawn equals P+Y');
        assertEq(token.balanceOf(BUYER), buyerBalBefore + got, 'buyer net position');
        assertEq(vault.claimableBalances(wf, BUYER), 0, 'no claimable remains after withdrawal');
    }

    /// @notice Same as above but with a non-zero protocol fee configured. Because the
    ///         emergency API returns an undifferentiated recovered amount and core does not
    ///         subject recovery to yield-fee classification (yieldOut = 0 on the emergency
    ///         path), the protocol yield fee must NOT be applied — even though the recovered
    ///         amount exceeds principal. This is accepted policy: recovery operators are
    ///         privileged incident actors, and choosing the recovery path may waive yield fees.
    ///         Assert the fee bucket stays 0.
    function test_emergencyUnwind_positiveYield_noProtocolFeeEvenWhenFeeConfigured() public {
        // Configure a non-zero fee BEFORE the escrow is created so it is snapshotted.
        vault.setYieldProtocolFeeBps(1000);

        uint256 wf = _openEscrow();
        module.setEmergencyReverts(false);
        module.setRecoverAmount(AMOUNT + YIELD);

        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.claimableBalances(wf, BUYER), AMOUNT + YIELD, 'beneficiary receives full P+Y');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'fee never charged on emergency recovery');

        uint256 buyerBalBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, AMOUNT + YIELD, 'withdrawn equals P+Y');
        assertEq(token.balanceOf(BUYER), buyerBalBefore + got, 'buyer net position');
    }

    /// @notice emergencyUnwind returns exactly 0 (a SUCCESSFUL return — semantically distinct
    ///         from an emergency call that reverts). With a non-zero principal this must hit
    ///         the PartialRecoveryNotAllowed guard and roll back atomically, validating the
    ///         explicit no-sentinel recoverAmount semantics.
    function test_emergencyUnwind_zeroReturn_hitsPartialRecoveryGuard() public {
        uint256 wf = _openEscrow();
        module.setEmergencyReverts(false);
        module.setRecoverAmount(0); // explicit successful return of zero

        uint256 moduleBalBefore = token.balanceOf(address(module));
        uint256 vaultBalBefore = token.balanceOf(address(vault));

        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vm.expectRevert(PartialRecoveryNotAllowed.selector);
        vault.recipientCancel(wf);

        // Atomic rollback: no transfer occurred (0 is not > 0), and the module's delete pos
        // was reverted along with the escrow state.
        assertEq(token.balanceOf(address(module)), moduleBalBefore, 'module balance unchanged');
        assertEq(token.balanceOf(address(vault)), vaultBalBefore, 'vault balance unchanged');
        assertEq(vault.v25YieldModules(wf), address(module), 'linkage preserved');
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'principal reference preserved');
        assertEq(vault.claimableBalances(wf, BUYER), 0, 'no claimable credited');
        assertEq(
            uint8(vault.getEscrowState(wf)),
            uint8(EscrowState.PENDING),
            'escrow remains PENDING'
        );
    }
}
