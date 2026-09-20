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

/// @notice Deterministic yield module that FORCES the emergency-unwind path through
///         EscrowYield._handleYieldModuleUnwind: unwindToEscrow always reverts (so the
///         normal unwind branch fails) while emergencyUnwind succeeds and returns the full
///         fundable principal back to the escrow. This exercises the catch -> emergencyUnwind
///         branch and proves the beneficiary can claim + withdraw the recovered principal.
contract EmergencyFallbackYieldModule is IYieldModule {
    using SafeERC20 for IERC20;

    struct Pos {
        address token;
        uint256 principal;
    }
    mapping(address escrow => mapping(uint256 escrowId => Pos)) private pos;

    // When false, unwindToEscrow reverts (forced fallback) and emergencyUnwind returns
    // principal + this extra yield. Configurable to prove the emergency branch.
    uint256 public emergencyYield;

    function setEmergencyYield(uint256 y) external { emergencyYield = y; }

    function initializeYield(uint256 escrowId, address token, uint256 amount, YieldPreset yieldMode)
        external returns (uint256) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        pos[msg.sender][escrowId] = Pos(token, amount);
        emit YieldInitialized(escrowId, token, amount, yieldMode);
        return amount;
    }

    // Force the normal-unwind path to fail so EscrowYield falls back to emergencyUnwind.
    function unwindToEscrow(uint256, address, uint256) external pure returns (uint256, uint256) {
        revert('mock: normal unwind unavailable');
    }

    // The emergency path succeeds: return full principal + emergencyYield back to the escrow.
    function emergencyUnwind(uint256 escrowId, address token, uint256)
        external returns (uint256 recovered) {
        Pos memory p = pos[msg.sender][escrowId];
        delete pos[msg.sender][escrowId];
        recovered = p.principal + emergencyYield;
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
        return ('EmergencyFallbackYieldModule', '1.0.0', keccak256('mock-emergency'));
    }
}

/**
 * @title EmergencyUnwindBeneficiaryClaimE2ETest
 * @notice Escrow-level end-to-end proving that when a yield module's normal unwind is
 *         unavailable, the escrow falls back to emergencyUnwind and the beneficiary can
 *         still claim and withdraw the recovered principal + emergency yield.
 *
 *         Path under test (EscrowYield._handleYieldModuleUnwind):
 *           unwindToEscrow reverts  (normal)
 *         -> emergencyUnwind succeeds (fallback)
 *         -> recovered >= principal  (PartialRecoveryNotAllowed guard passes)
 *         -> _finalizeClaimableSettlement credits beneficiary
 *         -> beneficiary withdrawEscrow pulls principal + yield
 */
contract EmergencyUnwindBeneficiaryClaimE2ETest is Test {
    EscrowVault internal vault;
    EmergencyFallbackYieldModule internal module;
    ModuleSnapshotRegistry internal registry;
    EscrowCreationPolicy internal policy;
    ERC20Mock internal token;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        token = new ERC20Mock('Token', 'TKN', address(this), 0);
        module = new EmergencyFallbackYieldModule();
        registry = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));

        vault = new EscrowVault(0, FEE, address(registry));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        // Full recovery to beneficiary (fee math is covered separately).
        vault.setYieldProtocolFeeBps(0);
        vault.setCreationPolicy(address(policy));

        registry.registerEscrowContract(address(vault));

        registry.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(module));
        registry.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(new DefaultReleaseStrategy()));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        token.mint(BUYER, 1_000_000e18);
        // Fund the module so it can pay principal + emergencyYield back on the fallback.
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
    }

    /// @notice Mutual cancel with emergency fallback: sender (TO_SENDER) claims & withdraws
    ///         the full principal recovered via emergencyUnwind.
    function test_emergencyUnwind_cancel_senderClaimsAndWithdrawsPrincipal() public {
        uint256 wf = _openEscrow();

        // Force the emergency path: normal unwind reverts; emergency returns exactly principal.
        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position/mock linkage cleared after emergency unwind');
        uint256 claimable = vault.claimableBalances(wf, BUYER);
        assertEq(claimable, AMOUNT, 'sender claimable = principal recovered via emergency unwind');
        assertEq(vault.totalFeesPerToken(address(token)), 0, 'emergency principal recovery incurs no fee');

        uint256 buyerBalBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(BUYER), buyerBalBefore + got, 'sender net position after emergency unwind');
    }

    /// @notice RELEASE with emergency fallback: recipient (seller) claims & withdraws principal.
    function test_emergencyUnwind_release_recipientClaimsAndWithdrawsPrincipal() public {
        uint256 wf = _openEscrow();

        vm.prank(BUYER);
        vault.release(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'linkage cleared on release');
        uint256 claimable = vault.claimableBalances(wf, SELLER);
        assertEq(claimable, AMOUNT, 'recipient claimable = principal recovered via emergency unwind');

        uint256 sellerBalBefore = token.balanceOf(SELLER);
        vm.prank(SELLER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(SELLER), sellerBalBefore + got, 'recipient net position');
    }

    /// @notice Emergency fallback can also return principal + yield to the beneficiary and the
    ///         beneficiary withdraws it all.
    function test_emergencyUnwind_withYield_beneficiaryWithdrawsPrincipalAndYield() public {
        uint256 wf = _openEscrow();
        uint256 emgYield = 50e18;
        module.setEmergencyYield(emgYield);

        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'linkage cleared');
        uint256 claimable = vault.claimableBalances(wf, BUYER);
        assertEq(claimable, AMOUNT + emgYield, 'sender claimable = principal + emergency yield');

        uint256 buyerBalBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(BUYER), buyerBalBefore + got, 'buyer net position incl. emergency yield');
    }
}
