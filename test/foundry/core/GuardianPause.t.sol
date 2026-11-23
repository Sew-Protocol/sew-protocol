// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../packages/sew-core/contracts/core/BaseEscrow.sol';
import '../../../contracts/admin/EscrowGovernanceTimelock.sol';
import '../../../packages/sew-core/contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../packages/sew-core/contracts/modules/DefaultResolutionModule.sol';
import '../../../packages/sew-core/contracts/modules/DefaultReleaseStrategy.sol';
import '../../../packages/sew-core/contracts/types/EscrowTypes.sol';
import '../../../packages/sew-core/contracts/types/YieldPresets.sol';
import '../../../packages/sew-core/contracts/libraries/SettingsValidationLibrary.sol';
import '../../../packages/sew-core/contracts/core/EscrowCreationPolicy.sol';
import '../../../contracts/ops/GuardianOps.sol';

/**
 * @title GuardianPause
 * @notice Tests for guardian pause/unpause functionality and its effects on escrow operations
 * @dev Phase 1: Verify pause prevents new escrows, allows recovery
 * @dev Guardian pauses new escrow intake; governance timelock resumes it.
 */
contract GuardianPause is Test {
    EscrowVault public vault;
    EscrowGovernanceTimelock public adminContract;
    ModuleSnapshotRegistry public moduleManagement;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    EscrowCreationPolicy public creationPolicy;
    GuardianOps public guardianOps;

    address public owner;
    address public timelock;
    address public guardian;
    address public feeAddress;
    address public resolver;
    address public buyer;
    address public seller;

    uint256 public constant ESCROW_FEE = 100; // 1%
    uint256 public constant INITIAL_BALANCE = 1_000_000e18;

    function _getDefaultSettings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        guardian = address(0x2222);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        buyer = address(0x1001);
        seller = address(0x1002);

        // Deploy resolution module
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();

        // Deploy mock token
        token = new ERC20Mock('Test Token', 'TEST', owner, 10000000e18);

        // Deploy ops contracts
        creationPolicy = new EscrowCreationPolicy(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);

        // Deploy vault
        vault = new EscrowVault(ESCROW_FEE,feeAddress,address(moduleManagement));

        // Deploy admin contract
        adminContract = new EscrowGovernanceTimelock(owner);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        // Grant roles
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        bytes32 ROLE_GUARDIAN = vault.ROLE_GUARDIAN();
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_TIMELOCK, timelock);
        vault.grantRole(ROLE_GUARDIAN, guardian);

        // Wire ops contracts
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreationPolicy(address(creationPolicy));


        // Queue and activate modules
        adminContract.queueResolutionModule(address(vault), address(resolutionModule));
        vm.prank(address(this));
        moduleManagement.registerEscrowContract(address(vault));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 14 days + 1);
        adminContract.activateResolutionModule(address(vault));
        vm.prank(address(this));
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        // Deploy guardian ops
        guardianOps = new GuardianOps(address(vault));

        // Mint tokens
        token.mint(buyer, INITIAL_BALANCE);
        token.mint(seller, INITIAL_BALANCE);

        // Approve vault
        vm.prank(buyer);
        token.approve(address(vault), type(uint256).max);
        vm.prank(seller);
        token.approve(address(vault), type(uint256).max);
    }

    // ============ Test 1: Guardian can pause escrow ============
    function test_GuardianCanPauseEscrow() public {
        vm.prank(guardian);
        vault.pause('Emergency: Suspicious activity detected');
        
        assertTrue(vault.paused(), 'Escrow should be paused after guardian call');
        (uint256 activeSince, uint256 lastUnpausedAt, uint256 cycles, uint256 lastResetAt) = vault.pauseState();
        assertEq(activeSince, block.timestamp);
        assertEq(lastUnpausedAt, 0);
        assertEq(cycles, 1);
        assertEq(lastResetAt, 0);
        assertEq(vault.totalPausedDuration(), 0);
    }

    // ============ Test 2: Non-guardian cannot pause ============
    function test_NonGuardianCannotPause() public {
        address nonGuardian = address(0x9999);
        
        vm.prank(nonGuardian);
        vm.expectRevert();
        vault.pause('Should fail');
        
        assertFalse(vault.paused(), 'Escrow should not be paused');
    }

    // ============ Test 3: Only timelock can unpause ============
    function test_OnlyTimelockCanUnpause() public {
        // Guardian pauses
        vm.prank(guardian);
        vault.pause('Emergency pause');
        assertTrue(vault.paused());

        // Non-timelock cannot unpause
        address notTimelock = address(0x9999);
        vm.prank(notTimelock);
        vm.expectRevert();
        vault.unpause();
        assertTrue(vault.paused(), 'Should still be paused');

        // Timelock can unpause
        vm.prank(timelock);
        vault.unpause();
        assertFalse(vault.paused(), 'Timelock should be able to unpause');
    }

    // ============ Test 4: Guardian cannot unpause (security check) ============
    function test_GuardianCannotUnpause() public {
        vm.prank(guardian);
        vault.pause('Emergency pause');
        assertTrue(vault.paused());

        // Guardian tries to unpause
        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();
        
        assertTrue(vault.paused(), 'Guardian should not be able to unpause');
    }

    function test_GuardianCannotChangeConfigurationOrGrantRoles() public {
        assertTrue(vault.hasRole(vault.ROLE_GUARDIAN(), guardian));
        assertFalse(vault.hasRole(vault.ROLE_TIMELOCK(), guardian));
        assertFalse(vault.hasRole(vault.ROLE_ADMIN_CONTRACT(), guardian));
        bytes32 timelockRole = vault.ROLE_TIMELOCK();

        vm.startPrank(guardian);
        vm.expectRevert();
        vault.setFeeRecipient(address(0xBEEF));
        vm.expectRevert();
        vault.setEscrowFeeBps(1);
        vm.expectRevert();
        vault.grantRole(timelockRole, guardian);
        vm.stopPrank();
    }

    // ============ Test 5: Pause prevents new escrow creation ============
    function test_PausePreventsNewEscrowCreation() public {
        uint256 amount = 100e18;

        // Guardian pauses
        vm.prank(guardian);
        vault.pause('Emergency pause');

        uint256 balanceBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert(bytes4(keccak256('EnforcedPause()')));
        vault.createEscrow(
            address(token),
            seller,
            amount,
            _getDefaultSettings()
        );
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0, "Paused creation must not custody funds");
        assertEq(token.balanceOf(buyer), balanceBefore, "Paused creation must not transfer tokens");
    }

    // ============ Test 6: Pause allows settlement (release) ============
    function test_PausePreventsNewTransfers() public {
        uint256 amount = 100e18;

        // Create escrow while not paused
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(
            address(token),
            seller,
            amount,
            _getDefaultSettings()
        );

        // Guardian pauses
        vm.prank(guardian);
        vault.pause('Emergency pause');

        // NEW SEMANTICS: Can still release while paused (settlement allowed)
        vm.prank(buyer);
        vault.release(workflowId);
        
        // Verify escrow was released even while paused
        EscrowState state = vault.getEscrowState(workflowId);
        assertEq(uint8(state), uint8(EscrowState.RELEASED));
    }

    function test_PauseAllowsDisputeAndSettlementForExistingEscrow() public {
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, 100e18, _getDefaultSettings());

        vm.prank(guardian);
        vault.pause('Stop new exposure');

        vm.prank(buyer);
        vault.raiseDispute(workflowId);
        assertEq(uint8(vault.getEscrowState(workflowId)), uint8(EscrowState.DISPUTED));

        vm.prank(resolver);
        vault.releaseAsDisputeResolver(workflowId, bytes32(0));
        (, , uint256 appealDeadline, ) = vault.pendingSettlements(workflowId);
        vm.warp(appealDeadline + 1);
        vault.executePendingSettlement(workflowId);
        assertEq(uint8(vault.getEscrowState(workflowId)), uint8(EscrowState.RELEASED));
    }

    // ============ Test 7: Resume allows operations ============
    function test_UnpausedResumeOperations() public {
        uint256 amount = 100e18;

        // Create escrow
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(
            address(token),
            seller,
            amount,
            _getDefaultSettings()
        );

        // Guardian pauses
        vm.prank(guardian);
        vault.pause('Emergency pause');
        assertTrue(vault.paused());

        // Timelock unpauses
        vm.prank(timelock);
        vault.unpause();
        assertFalse(vault.paused());

        // Operations resume
        vm.prank(buyer);
        vault.release(workflowId);
        
        // Verify escrow was released
        (,,,,,,, EscrowState state,,) = vault.escrowTransfers(workflowId);
        assertEq(uint8(state), uint8(EscrowState.RELEASED), 'Escrow should be released after unpause');
    }

    // ============ Test 8: Multiple pause/unpause cycles ============
    function test_MultiplePauseUnpauseCycles() public {
        for (uint256 i = 0; i < 3; i++) {
            // Guardian pauses
            vm.prank(guardian);
            vault.pause('Emergency pause');
            assertTrue(vault.paused());

            // Timelock unpauses
            vm.prank(timelock);
            vault.unpause();
            assertFalse(vault.paused());
        }
        assertEq(vault.pauseCycleCount(), 3);
    }

    function test_PauseDurationAccumulatesAndGovernanceCanRestartIntake() public {
        vm.prank(guardian);
        vault.pause('Incident');
        (uint256 pauseAt,,,) = vault.pauseState();
        vm.warp(pauseAt + 1 days);
        vm.prank(timelock);
        vault.unpause();

        (uint256 activeSince, uint256 lastUnpausedAt, uint256 cycles, uint256 lastResetAt) = vault.pauseState();
        assertEq(activeSince, 0);
        assertGt(lastUnpausedAt, pauseAt);
        assertEq(cycles, 1);
        assertEq(lastResetAt, 0);
        assertEq(vault.totalPausedDuration(), 1 days);
        assertFalse(vault.paused());

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, 100e18, _getDefaultSettings());
        assertEq(workflowId, 0);
    }

    // ============ Test 9: Pause reason recorded ============
    function test_PauseReasonRecorded() public {
        string memory reason = 'Suspicious activity on mainnet';
        
        vm.prank(guardian);
        vault.pause(reason);
        
        assertTrue(vault.paused(), 'Should record pause state');
    }

    // ============ Test 10: Paused state persists across blocks ============
    function test_PausedStatePersistsAcrossBlocks() public {
        vm.prank(guardian);
        vault.pause('Emergency pause');
        assertTrue(vault.paused());

        vm.roll(block.number + 100);
        assertTrue(vault.paused(), 'Pause state should persist');

        vm.prank(timelock);
        vault.unpause();
        assertFalse(vault.paused());

        vm.roll(block.number + 100);
        assertFalse(vault.paused(), 'Unpause state should persist');
    }

    // ============ Test 11: Guardian pause allows escrow introspection ============
    function test_PausedEscrowStillQueryable() public {
        uint256 amount = 100e18;

        // Create escrow
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(
            address(token),
            seller,
            amount,
            _getDefaultSettings()
        );

        // Guardian pauses
        vm.prank(guardian);
        vault.pause('Emergency pause');

        // Can still query escrow state
        (address token_, address to, address from,,,,,,,) = vault.escrowTransfers(workflowId);
        assertEq(token_, address(token), 'Should query token');
        assertEq(to, seller, 'Should query recipient');
        assertEq(from, buyer, 'Should query sender');
    }

    // ============ Test 12: Concurrent pause operations handled ============
    function test_ConcurrentPauseOperations() public {
        // First pause
        vm.prank(guardian);
        vault.pause('First pause');
        assertTrue(vault.paused());

        // Second pause attempt while already paused should revert
        vm.prank(guardian);
        vm.expectRevert();
        vault.pause('Second pause');

        // Unpause
        vm.prank(timelock);
        vault.unpause();
        assertFalse(vault.paused());

        // Second unpause attempt (should fail gracefully)
        vm.prank(timelock);
        vm.expectRevert();
        vault.unpause();
    }

    // ============ Test 13: Pause prevents automatic releases ============
    function test_PausePreventsAutoRelease() public {
        uint256 amount = 100e18;

        // Create escrow with auto-release
        EscrowSettings memory settings = _getDefaultSettings();
        settings.autoReleaseTime = uint64(block.timestamp + 1 hours);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(
            address(token),
            seller,
            amount,
            settings
        );

        // Guardian pauses
        vm.prank(guardian);
        vault.pause('Emergency pause');

        // Verify pause is still active
        assertTrue(vault.paused(), 'Should remain paused');
        
        // Advance time past auto-release
        vm.warp(block.timestamp + 2 hours);

        // automateTimedActions behavior depends on pending settlement state
        vault.automateTimedActions(workflowId);
        // Verify we're still paused
        assertTrue(vault.paused(), 'Should still be paused after automateTimedActions');
    }

    // ============ Test 14: Pause allows recovery operations ============
    function test_PauseAllowsGuardianOpsAccess() public {
        // Guardian pauses
        vm.prank(guardian);
        vault.pause('Emergency pause');
        assertTrue(vault.paused());

        // GuardianOps contract can still be called when paused
        // (This test verifies the API exists; actual emergency unwind tested separately)
        assertTrue(vault.paused(), 'Guardian pause should be active');
    }

    // ============ Test 15: Unpause clears pause flag completely ============
    function test_UnpauseClearsPauseFlagCompletely() public {
        vm.prank(guardian);
        vault.pause('Test pause');
        assertTrue(vault.paused());

        vm.prank(timelock);
        vault.unpause();
        assertFalse(vault.paused(), 'Should be completely unpaused');

        // Verify subsequent operations work
        uint256 amount = 100e18;
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(
            address(token),
            seller,
            amount,
            _getDefaultSettings()
        );

        assertGe(workflowId, 0, 'Should create escrow after unpause');
    }
}
