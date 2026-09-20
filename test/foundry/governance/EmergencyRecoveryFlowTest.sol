// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/ops/GuardianOps.sol';
import 'contracts/governance/EmergencyRecoveryProposal.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowCreationPolicy.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/types/YieldPresets.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title EmergencyRecoveryFlowTest
 * @notice End-to-end coverage of the emergency unwinding feature:
 *         EscrowVault -> AaveYieldModule -> GuardianOps -> EmergencyRecoveryProposal.
 *
 * Covers:
 *   - GuardianOps.emergencyUnwindAavePosition (guardian auth, proceeds to escrow)
 *   - GuardianOps recovery-operator wiring on the Aave module
 *   - Full EMERGENCY_UNWIND_AAVE governance proposal lifecycle (propose/approve/execute)
 *   - Safety gates: recovery disabled, non-guardian, failed-execution path
 *
 * Run: forge test --match-contract EmergencyRecoveryFlowTest -vvv
 */
contract EmergencyRecoveryFlowTest is Test {
    EscrowVault internal vault;
    AaveYieldModule internal aaveModule;
    MockAavePool internal pool;
    MockAToken internal aToken;
    ERC20Mock internal token;
    ModuleSnapshotRegistry internal registry;
    EscrowCreationPolicy internal policy;
    GuardianOps internal guardianOps;
    EmergencyRecoveryProposal internal recoveryProposal;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    address internal constant GUARDIAN = address(0x6A11);
    address internal constant TIMELOCK = address(0x71FE);
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        token = new ERC20Mock('Token', 'TKN', address(this), 0);
        aToken = new MockAToken(address(token), 'aTKN', 'aTKN');
        pool = new MockAavePool();
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));

        // Aave module (pull model)
        aaveModule = new AaveYieldModule(address(pool));
        _configureToken(aaveModule, address(token), address(aToken));

        registry = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));

        vault = new EscrowVault(0, FEE, address(registry));
        _approveEscrow(aaveModule, address(vault));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreationPolicy(address(policy));

        registry.registerEscrowContract(address(vault));

        bytes32 roleGuardian = vault.ROLE_GUARDIAN();
        vault.grantRole(roleGuardian, GUARDIAN);

        // Make the Aave module the default YIELD_GEN module for the vault.
        registry.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);

        // GuardianOps + recovery operator wiring.
        guardianOps = new GuardianOps(address(vault));
        aaveModule.setRecoveryOperator(address(guardianOps), true);

        // Recovery proposal contract (this test is admin/proposer/executor + guardian on vault)
        recoveryProposal = new EmergencyRecoveryProposal(address(vault), address(guardianOps), address(this));
        recoveryProposal.setRecoveryEnabled(true);
        vault.grantRole(roleGuardian, address(recoveryProposal));

        token.mint(BUYER, 1_000_000e18);
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
    }

    // ---- Slow-lane two-step helpers (queue -> warp to eta -> activate) ----
    // These warp to the exact pending eta so they do not shift later relative timing.
    function _configureToken(AaveYieldModule m, address token_, address aToken_) internal {
        m.queueConfigureToken(token_, aToken_);
        (, uint64 eta, ) = m.getPendingConfigureToken(token_);
        vm.warp(eta);
        m.activateConfigureToken(token_);
    }

    function _approveEscrow(AaveYieldModule m, address escrow_) internal {
        m.queueApproveEscrow(escrow_);
        (, uint64 eta, ) = m.getPendingApproveEscrow();
        vm.warp(eta);
        m.activateApproveEscrow();
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

    /// @dev Open an escrow that funds an Aave yield position; returns a NONZERO workflowId.
    ///      The first workflow id is 0, which proposeRecoveryWithUnwindTarget rejects, so we
    ///      always open a warm-up escrow first to guarantee the returned id is >= 1.
    function _openEscrowWithYield() internal returns (uint256 wf) {
        vm.prank(BUYER);
        uint256 warmup = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        assertEq(warmup, 0);

        vm.prank(BUYER);
        wf = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        assertGt(wf, 0, 'workflow id must be nonzero for recovery target');

        assertEq(vault.v25YieldModules(wf), address(aaveModule), 'yield module recorded');
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'yield principal recorded');
        assertGt(aToken.balanceOf(address(aaveModule)), 0, 'module holds aTokens');
    }

    // ================= GuardianOps direct emergency unwind =================

    function test_guardianOps_emergencyUnwindAavePosition_unwindsToVault() public {
        uint256 wf = _openEscrowWithYield();
        pool.simulateYield(address(token), 10);

        uint256 vaultBalBefore = token.balanceOf(address(vault));
        uint256 principalExpected = vault.v25YieldPrincipals(wf);

        vm.prank(GUARDIAN);
        uint256 unwound = guardianOps.emergencyUnwindAavePosition(
            address(token),
            wf,
            address(vault)
        );

        // INVARIANT 2: proceeds go to the escrow vault, never to the guardian/caller.
        assertEq(token.balanceOf(address(vault)), vaultBalBefore + unwound);
        assertGe(unwound, principalExpected, 'recovered at least principal');

        // Position cleared in the module.
        (, uint256 principal, , ) = aaveModule.positions(address(vault), wf);
        assertEq(principal, 0);

        // Note: the vault's v25YieldModules/v25YieldPrincipals bookkeeping is intentionally
        // not cleared here — GuardianOps unwinds the module position directly (escrow-level
        // recovery), and the vault's own unwind path would re-detect the cleared module
        // position on the next release/cancel. Position cleared in the module is sufficient.
    }

    function test_guardianOps_nonGuardianReverts() public {
        uint256 wf = _openEscrowWithYield();

        vm.prank(BUYER);
        vm.expectRevert(
            abi.encodeWithSelector(GuardianOps.NotGuardian.selector, BUYER)
        );
        guardianOps.emergencyUnwindAavePosition(address(token), wf, address(vault));
    }

    function test_guardianOps_recoveryOperatorRevokedReverts() public {
        uint256 wf = _openEscrowWithYield();

        // Revoke GuardianOps as a recovery operator: the module rejects the unwind.
        aaveModule.setRecoveryOperator(address(guardianOps), false);

        vm.prank(GUARDIAN);
        vm.expectRevert("UnauthorizedEscrow");
        guardianOps.emergencyUnwindAavePosition(address(token), wf, address(vault));
    }

    function test_guardianOps_moduleNotConfiguredReverts() public {
        uint256 wf = _openEscrowWithYield();

        // Point GuardianOps at a vault with no YIELD_GEN module configured.
        GuardianOps bare = new GuardianOps(address(vault));
        // New unregistered registry has no module for the vault.
        ModuleSnapshotRegistry bareRegistry = new ModuleSnapshotRegistry(address(this));
        EscrowVault bareVault = new EscrowVault(0, FEE, address(bareRegistry));
        GuardianOps ops = new GuardianOps(address(bareVault));
        bareVault.grantRole(bareVault.ROLE_GUARDIAN(), GUARDIAN);

        vm.prank(GUARDIAN);
        vm.expectRevert(GuardianOps.ModuleNotConfigured.selector);
        ops.emergencyUnwindAavePosition(address(token), wf, address(bareVault));
    }

    function test_guardianOps_invalidTargetReverts() public {
        uint256 wf = _openEscrowWithYield();

        // The unwind target must be the vault that GuardianOps is bound to. Passing an
        // unrelated contract must be rejected before any module interaction.
        vm.prank(GUARDIAN);
        vm.expectRevert(
            abi.encodeWithSelector(GuardianOps.InvalidEscrowTarget.selector, address(0xDEAD))
        );
        guardianOps.emergencyUnwindAavePosition(address(token), wf, address(0xDEAD));
    }

    function test_guardianOps_cooldownRevertsOnRapidReentry() public {
        // Open a warm-up escrow first (workflow 0), then two real funded positions.
        vm.prank(BUYER);
        uint256 warmup = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        assertEq(warmup, 0);

        vm.prank(BUYER);
        uint256 wf1 = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        vm.prank(BUYER);
        uint256 wf2 = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        assertGt(wf1, 0);
        assertGt(wf2, 0);

        uint256 t = block.timestamp;

        // First unwind succeeds and arms the per-token cooldown.
        vm.prank(GUARDIAN);
        uint256 unwound = guardianOps.emergencyUnwindAavePosition(address(token), wf1, address(vault));
        assertGt(unwound, 0, 'first unwind succeeds');

        // An immediate second unwind of a different position must be blocked by cooldown.
        vm.prank(GUARDIAN);
        vm.expectRevert(
            abi.encodeWithSelector(GuardianOps.CooldownNotExpired.selector, address(token), t, t)
        );
        guardianOps.emergencyUnwindAavePosition(address(token), wf2, address(vault));

        // Once the cooldown window passes, the second position can be unwound.
        vm.warp(t + guardianOps.UNWIND_COOLDOWN() + 1);
        vm.prank(GUARDIAN);
        uint256 unwound2 = guardianOps.emergencyUnwindAavePosition(address(token), wf2, address(vault));
        assertGt(unwound2, 0, 'second unwind succeeds after cooldown');
    }

    function test_guardianOps_unwindUsesRecordedModuleAfterUpgrade() public {
        // Fund a position into the currently-default module (aaveModule).
        uint256 wf = _openEscrowWithYield();
        assertEq(vault.v25YieldModules(wf), address(aaveModule), 'recorded module is aaveModule');

        // Simulate a module upgrade: deploy a new module and make it the registry default.
        AaveYieldModule newModule = new AaveYieldModule(address(pool));
        _configureToken(newModule, address(token), address(aToken));
        _approveEscrow(newModule, address(vault));
        newModule.setRecoveryOperator(address(guardianOps), true);
        registry.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(newModule));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);

        // The workflow still records the ORIGINAL module, even though the default changed.
        assertEq(vault.v25YieldModules(wf), address(aaveModule), 'workflow records original module');
        assertEq(registry.getModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN), address(newModule), 'default is now newModule');

        // An emergency unwind must route through the RECORDED module (which holds the
        // position), not the new default. If it used the default, it would find no position
        // and revert (TokenMismatch), so this test fails pre-fix.
        uint256 principalExpected = vault.v25YieldPrincipals(wf);
        vm.prank(GUARDIAN);
        uint256 unwound = guardianOps.emergencyUnwindAavePosition(address(token), wf, address(vault));
        assertGe(unwound, principalExpected, 'funds recovered via recorded module');

        // Position cleared on the recorded module; new module holds nothing.
        (, uint256 principal, , ) = aaveModule.positions(address(vault), wf);
        assertEq(principal, 0, 'position cleared on recorded module');
        (, uint256 newPrincipal, , ) = newModule.positions(address(vault), wf);
        assertEq(newPrincipal, 0, 'new module has no position');
    }

    function test_guardianOps_maxUnwindPerCallReverts() public {
        // Deposit a position larger than the per-call unwind cap.
        uint256 maxAllowed = guardianOps.MAX_UNWIND_AMOUNT_PER_CALL();
        uint256 bigAmount = maxAllowed * 2;

        token.mint(BUYER, bigAmount);
        vm.startPrank(BUYER);
        token.approve(address(vault), type(uint256).max);
        // Open a warm-up escrow (workflow 0) so the large position gets a nonzero id.
        vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        uint256 wf = vault.createEscrow(address(token), SELLER, bigAmount, _settings());
        vm.stopPrank();
        assertEq(vault.v25YieldPrincipals(wf), bigAmount, 'large principal recorded');

        vm.prank(GUARDIAN);
        vm.expectRevert(
            abi.encodeWithSelector(GuardianOps.AmountExceedsLimit.selector, bigAmount, maxAllowed)
        );
        guardianOps.emergencyUnwindAavePosition(address(token), wf, address(vault));

        // The revert rolls back the whole transaction, so the position is untouched.
        (, uint256 principal, , ) = aaveModule.positions(address(vault), wf);
        assertEq(principal, bigAmount, 'position preserved when unwind cap exceeded');
    }

    // ================= EmergencyRecoveryProposal lifecycle =================

    function test_recovery_disabledBlocksProposal() public {
        recoveryProposal.setRecoveryEnabled(false);
        vm.expectRevert(EmergencyRecoveryProposal.RecoveryDisabled.selector);
        recoveryProposal.proposeRecovery(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            'no incident'
        );
    }

    function test_recovery_proposeApproveExecute_unwindsAave() public {
        uint256 wf = _openEscrowWithYield();
        pool.simulateYield(address(token), 10);

        uint256 proposalId = recoveryProposal.proposeRecoveryWithUnwindTarget(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            'unwind',
            address(token),
            wf,
            address(vault)
        );

        // Cannot execute before approval.
        vm.expectRevert();
        recoveryProposal.executeRecovery(proposalId);

        recoveryProposal.approveRecovery(proposalId);

        // Cannot execute before the 2-day timelock delay.
        vm.expectRevert();
        recoveryProposal.executeRecovery(proposalId);

        vm.warp(block.timestamp + 2 days + 1);

        uint256 vaultBalBefore = token.balanceOf(address(vault));
        recoveryProposal.executeRecovery(proposalId);

        EmergencyRecoveryProposal.RecoveryProposal memory p = recoveryProposal.getRecoveryProposal(proposalId);
        assertEq(uint8(p.status), uint8(EmergencyRecoveryProposal.RecoveryStatus.EXECUTED));
        assertGt(token.balanceOf(address(vault)), vaultBalBefore, 'proceeds returned to the vault');
        // Vault-level bookkeeping is not cleared by the direct module unwind (see GuardianOps test).
    }

    function test_recovery_executeFailsWithoutGuardianRole() public {
        uint256 wf = _openEscrowWithYield();

        // Deploy a separate recovery contract that is NOT granted ROLE_GUARDIAN on the vault.
        EmergencyRecoveryProposal noRole = new EmergencyRecoveryProposal(
            address(vault),
            address(guardianOps),
            address(this)
        );
        noRole.setRecoveryEnabled(true);

        uint256 proposalId = noRole.proposeRecoveryWithUnwindTarget(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            'unwind',
            address(token),
            wf,
            address(vault)
        );
        noRole.approveRecovery(proposalId);
        vm.warp(block.timestamp + 2 days + 1);

        // GuardianOps denies the non-guardian recovery contract => proposal marked FAILED.
        noRole.executeRecovery(proposalId);

        EmergencyRecoveryProposal.RecoveryProposal memory p = noRole.getRecoveryProposal(proposalId);
        assertEq(uint8(p.status), uint8(EmergencyRecoveryProposal.RecoveryStatus.FAILED));
        // Position is untouched.
        (, uint256 principal, , ) = aaveModule.positions(address(vault), wf);
        assertEq(principal, AMOUNT);
    }

    function test_recovery_noUnwindTargetReverts() public {
        vm.expectRevert(EmergencyRecoveryProposal.NoUnwindTarget.selector);
        recoveryProposal.proposeRecoveryWithUnwindTarget(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            'unwind',
            address(0),
            0,
            address(0)
        );
    }

    function test_recovery_proposeWithWrongActionReverts() public {
        vm.expectRevert('InvalidRecoveryAction');
        recoveryProposal.proposeRecoveryWithUnwindTarget(
            EmergencyRecoveryProposal.RecoveryAction.WITHDRAW_PAUSED_ESCROWS,
            'wrong',
            address(token),
            1,
            address(vault)
        );
    }

    function test_recovery_cancelBeforeExecute() public {
        uint256 wf = _openEscrowWithYield();

        uint256 proposalId = recoveryProposal.proposeRecoveryWithUnwindTarget(
            EmergencyRecoveryProposal.RecoveryAction.EMERGENCY_UNWIND_AAVE,
            'unwind',
            address(token),
            wf,
            address(vault)
        );
        recoveryProposal.cancelRecovery(proposalId, 'resolved');

        EmergencyRecoveryProposal.RecoveryProposal memory p = recoveryProposal.getRecoveryProposal(proposalId);
        assertEq(uint8(p.status), uint8(EmergencyRecoveryProposal.RecoveryStatus.CANCELLED));
    }
}
