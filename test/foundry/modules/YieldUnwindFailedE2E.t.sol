// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowCreationPolicy.sol';
import 'contracts/modules/DefaultReleaseStrategy.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/types/YieldPresets.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/interfaces/IYieldModule.sol';
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
    // Amount returned by emergencyUnwind when emergencyReverts == false.
    // 0 is treated as "return full principal". A value < principal triggers
    // PartialRecoveryNotAllowed in core.
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
        Pos memory p = pos[msg.sender][escrowId];
        delete pos[msg.sender][escrowId];
        recovered = recoverAmount == 0 ? p.principal : recoverAmount;
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
 *           1. unwindToEscrow reverts AND emergencyUnwind reverts -> the escrow emits
 *              YieldUnwindFailed, clears the module linkage, completes settlement from the
 *              remaining escrow balance (claimable-only), and the beneficiary can withdraw.
 *           2. unwindToEscrow reverts and emergencyUnwind returns recovered < principal
 *              -> core reverts PartialRecoveryNotAllowed and the escrow state is NOT cleared
 *              (the transaction rolls back entirely).
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

    event YieldUnwindFailed(uint256 indexed workflowId, address indexed token, uint256 principal);

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
        token.mint(address(module), 1_000_000e18);
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

    function _openEscrow() internal returns (uint256 wf) {
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BUYER);
        wf = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'yield principal recorded');
        // Principal now lives in the module, not the escrow.
        assertEq(token.balanceOf(address(vault)), 0, 'escrow emptied by yield deposit');
    }

    /// @notice Both unwind paths revert. The escrow must emit YieldUnwindFailed, clear the
    ///         module linkage, complete the lifecycle from the REMAINING escrow balance
    ///         (the amount == principal when there was no partial release), credit the
    ///         beneficiary, and let the beneficiary withdraw after assets are recovered.
    function test_bothPathsFail_emitsYieldUnwindFailed_andBeneficiaryClaimsRemaining() public {
        uint256 wf = _openEscrow();
        module.setEmergencyReverts(true);

        // Both paths fail, so principal stays stuck in the module. Simulate the admin
        // recovering assets back into the escrow so the claim is fundable. (The escrow's
        // remaining balance for this full settlement is the full principal `amount`.)
        token.mint(address(vault), AMOUNT);

        vm.prank(BUYER);
        vault.senderCancel(wf);

        vm.expectEmit(true, true, true, true, address(vault));
        emit YieldUnwindFailed(wf, address(token), AMOUNT);

        vm.prank(SELLER);
        vault.recipientCancel(wf);

        // Linkage cleared despite neither path having recovered the tokens.
        assertEq(vault.v25YieldModules(wf), address(0), 'module linkage cleared');
        assertEq(vault.v25YieldPrincipals(wf), 0, 'principal reference cleared');

        // Beneficiary entitlement equals the remaining escrow balance (full principal).
        uint256 claimable = vault.claimableBalances(wf, BUYER);
        assertEq(claimable, AMOUNT, 'sender claimable = remaining escrow balance');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'both-fail branch incurs no fee');

        // Beneficiary pulls the recovered assets.
        uint256 buyerBalBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(BUYER), buyerBalBefore + got, 'buyer net position');
    }

    /// @notice Both unwind paths fail during RELEASE; the recipient claims the remaining escrow
    ///         balance and withdraws after assets are recovered.
    function test_bothPathsFail_release_recipientClaimsAndWithdraws() public {
        uint256 wf = _openEscrow();
        module.setEmergencyReverts(true);
        token.mint(address(vault), AMOUNT);

        vm.expectEmit(true, true, true, true, address(vault));
        emit YieldUnwindFailed(wf, address(token), AMOUNT);

        vm.prank(BUYER);
        vault.release(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'linkage cleared on release');

        uint256 claimable = vault.claimableBalances(wf, SELLER);
        assertEq(claimable, AMOUNT, 'recipient claimable = remaining escrow balance');

        uint256 sellerBalBefore = token.balanceOf(SELLER);
        vm.prank(SELLER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(SELLER), sellerBalBefore + got, 'seller net position');
    }

    /// @notice emergencyUnwind returns less than the deposited principal. Core must revert
    ///         PartialRecoveryNotAllowed and (because the whole tx reverts) the escrow linkage
    ///         and claimable state must remain untouched.
    function test_partialRecovery_revertsPartialRecoveryNotAllowed() public {
        uint256 wf = _openEscrow();
        module.setEmergencyReverts(false);
        module.setRecoverAmount(AMOUNT - 1);

        vm.prank(BUYER);
        vault.senderCancel(wf);

        vm.prank(SELLER);
        vm.expectRevert(PartialRecoveryNotAllowed.selector);
        vault.recipientCancel(wf);

        // Revert did NOT clear the blocked/release linkage — the position is still recoverable.
        assertEq(vault.v25YieldModules(wf), address(module), 'linkage preserved on guard revert');
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'principal reference preserved');
        assertEq(vault.claimableBalances(wf, BUYER), 0, 'no claimable credited on guard revert');

        // Escrow still PENDING (whole tx reverted), so no withdrawal is possible.
        assertEq(
            uint8(vault.getEscrowState(wf)),
            uint8(EscrowState.PENDING),
            'escrow remains PENDING on guard revert'
        );
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

        assertEq(vault.v25YieldModules(wf), address(0), 'linkage cleared on exact recovery');
        assertEq(vault.claimableBalances(wf, BUYER), AMOUNT, 'sender claimable = recovered principal');
    }
}
