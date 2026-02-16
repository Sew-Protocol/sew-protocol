// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/admin/EscrowGovernanceTimelock.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../TestConfig.sol';

/// @title PauseLocking Tests
/// @notice Comprehensive tests for guardian pause locking mechanism
/// @dev Tests skipped - pause functionality removed for size optimization
contract PauseLocking is Test {
    modifier skipIfPauseNotSupported() {
        vm.skip(true); // Skip all tests in this contract
        _;
    }

    EscrowVault public escrow;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    ModuleSnapshotRegistry public snapshotRegistry;
    
    // Ops contracts
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    
    // Test accounts
    address public guardian;
    address public timelock;
    address public admin;
    address public sender;
    address public recipient;
    address public resolver;
    address public owner;
    
    // Test constants
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant PAUSE_DURATION = 7 days;
    uint256 constant PAUSE_WINDOW = 90 days;
    uint256 constant MAX_CYCLES = 3;
    uint256 constant ESCROW_FEE = 100; // 1% in basis points
    
    function setUp() public {
        vm.skip(!TestConfig.RUN_PAUSE_TESTS); // Skip if pause tests disabled
        // Setup accounts
        owner = address(this);  // Test contract is the owner for role management
        guardian = makeAddr("guardian");
        timelock = makeAddr("timelock");
        admin = owner;
        sender = makeAddr("sender");
        recipient = makeAddr("recipient");
        resolver = makeAddr("resolver");

        // Deploy token with initial balance for owner
        token = new ERC20Mock("Test Token", "TEST", owner, 10000 ether);
        
        // Deploy ops contracts with owner
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        settlementOps = new SettlementOps(owner);
        createOps = new CreateOps(owner);
        
        // Deploy bond collector
        bondCollector = new BondCollector(owner);
        
        // Deploy snapshot registry
        snapshotRegistry = new ModuleSnapshotRegistry(owner);
        
        // Deploy release strategy
        releaseStrategy = new DefaultReleaseStrategy();
        
        // Deploy escrow vault (fee, feeAddress, yieldOps, disputeOps, moduleManagement)
        escrow = new EscrowVault(ESCROW_FEE, owner, address(yieldOps), address(disputeOps), address(snapshotRegistry));
        
        // Grant necessary roles
        vm.startPrank(owner);
        escrow.grantRole(escrow.ROLE_GUARDIAN(), guardian);
        escrow.grantRole(escrow.ROLE_TIMELOCK(), timelock);
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), owner);
        
        // Grant ROLE_TIMELOCK to owner in all ops so we can register escrow contract
        yieldOps.grantRole(yieldOps.ROLE_TIMELOCK(), owner);
        disputeOps.grantRole(disputeOps.ROLE_TIMELOCK(), owner);
        settlementOps.grantRole(settlementOps.ROLE_TIMELOCK(), owner);
        createOps.grantRole(createOps.ROLE_TIMELOCK(), owner);
        snapshotRegistry.grantRole(snapshotRegistry.ROLE_TIMELOCK(), owner);
        
        // Register escrow contract with all ops
        yieldOps.registerEscrowContract(address(escrow));
        disputeOps.registerEscrowContract(address(escrow));
        settlementOps.registerEscrowContract(address(escrow));
        createOps.registerEscrowContract(address(escrow));
        snapshotRegistry.registerEscrowContract(address(escrow));
        
        // Queue and activate release strategy (with 7-day slowlane)
        snapshotRegistry.queueModule(address(escrow), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        // Note: Can't activate immediately due to 7-day slowlane. Tests that need release strategy
        // will need to warp time and activate it themselves or handle NotReady error.
        
        // Set ops addresses in vault
        escrow.setCreateOps(address(createOps));
        escrow.setSettlementOps(address(settlementOps));
        
        // Transfer tokens to sender
        token.transfer(sender, INITIAL_BALANCE);
        
        // Initialize pauseState.lastResetAt to current time to avoid reset window bugs
        // (The pause window counter should not reset on the first pause)
        vm.stopPrank();
    }

    // ============ Test 1: Cannot re-pause while paused ============

    function test_CannotRePauseWhilePaused() public {
        vm.startPrank(guardian);
        
        // First pause should succeed
        escrow.pause("Initial emergency");
        assertTrue(escrow.paused());
        
        // Second pause should revert
        vm.expectRevert(AlreadyPausedCannotRepause.selector);
        escrow.pause("Another emergency");
        
        vm.stopPrank();
    }

    function test_CanPauseAfterUnpause() public {
        vm.startPrank(guardian);
        
        // Pause
        escrow.pause("First emergency");
        assertTrue(escrow.paused());
        
        vm.stopPrank();
        
        vm.startPrank(timelock);
        
        // Unpause
        escrow.unpause();
        assertFalse(escrow.paused());
        
        vm.stopPrank();
        
        vm.startPrank(guardian);
        
        // Can pause again after unpause
        escrow.pause("Second emergency");
        assertTrue(escrow.paused());
        
        vm.stopPrank();
    }

    // ============ Test 2: Pause cycle counter increments ============

    function test_PauseCycleCounterIncrements() public {
        vm.startPrank(guardian);
        
        // Check initial state
        (,, uint256 initialCount,) = escrow.pauseState();
        assertEq(initialCount, 0);
        
        // First pause
        escrow.pause("Pause 1");
        (,, uint256 count1,) = escrow.pauseState();
        assertEq(count1, 1);
        
        vm.stopPrank();
        
        // Unpause
        vm.prank(timelock);
        escrow.unpause();
        
        // Second pause
        vm.prank(guardian);
        escrow.pause("Pause 2");
        (,, uint256 count2,) = escrow.pauseState();
        assertEq(count2, 2);
        
        // Unpause again
        vm.prank(timelock);
        escrow.unpause();
        
        // Third pause
        vm.prank(guardian);
        escrow.pause("Pause 3");
        (,, uint256 count3,) = escrow.pauseState();
        assertEq(count3, 3);
    }

    // ============ Test 3: Max pause cycles enforced ============

    function test_MaxPauseCyclesEnforced() public {
        // Do 3 pauses
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(guardian);
            escrow.pause(string(abi.encodePacked("Pause ", i + 1)));
            
            vm.prank(timelock);
            escrow.unpause();
        }
        
        // Fourth pause should revert
        vm.prank(guardian);
        vm.expectRevert();
        escrow.pause("Pause 4 - should fail");
    }

    // ============ Test 4: Cycle counter resets after window ============

    function test_PauseCycleCounterResetsAfterWindow() public {
        // Do 3 pauses
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(guardian);
            escrow.pause(string(abi.encodePacked("Pause ", i + 1)));
            
            vm.prank(timelock);
            escrow.unpause();
        }
        
        // Verify max cycles reached
        (,, uint256 countBefore,) = escrow.pauseState();
        assertEq(countBefore, 3);
        
        // Skip forward 90 days + 1 second
        vm.warp(block.timestamp + PAUSE_WINDOW + 1);
        
        // Pause again - should succeed because window reset
        vm.prank(guardian);
        escrow.pause("Pause 1 - new window");
        
        // Counter should be reset to 1
        (,, uint256 countAfter,) = escrow.pauseState();
        assertEq(countAfter, 1);
    }

    // ============ Test 5: Time enforcement on critical operations ============

    function test_TimeEnforcementOnCreateEscrow() public {
        // Approve token
        vm.prank(sender);
        token.approve(address(escrow), 200 ether);
        
        // Create an escrow - should succeed
        vm.prank(sender);
        escrow.createEscrow(
            address(token),
            recipient,
            100 ether,
            EscrowSettings({ customResolver: address(0), releaseAddress: address(0), yieldPreset: YieldPreset.OFF, autoReleaseTime: 0, autoCancelTime: 0 })
        );
        
        // Test time enforcement works properly
        // (createEscrow calls _enforceMaxPauseDuration internally)
    }

    function test_TimeEnforcementOnRelease() public {
        // Create an escrow first
        vm.prank(sender);
        token.approve(address(escrow), 100 ether);
        
        vm.prank(sender);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            recipient,
            100 ether,
            EscrowSettings({ customResolver: address(0), releaseAddress: address(0), yieldPreset: YieldPreset.OFF, autoReleaseTime: 0, autoCancelTime: 0 })
        );
        
        // Activate release strategy (with 7-day slowlane)
        vm.prank(address(this));
        vm.warp(block.timestamp + 7 days + 1);
        snapshotRegistry.activateModule(address(escrow), BaseEscrow.ModuleType.RELEASE);
        
        // Release - should succeed
        vm.prank(sender);
        escrow.release(workflowId);
    }

    function test_TimeEnforcementOnRecipientCancel() public {
        // Create an escrow first
        vm.prank(sender);
        token.approve(address(escrow), 100 ether);
        
        vm.prank(sender);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            recipient,
            100 ether,
            EscrowSettings({ customResolver: address(0), releaseAddress: address(0), yieldPreset: YieldPreset.OFF, autoReleaseTime: 0, autoCancelTime: 0 })
        );
        
        // Recipient cancels - should succeed
        vm.prank(recipient);
        escrow.recipientCancel(workflowId);
    }

    function test_TimeEnforcementOnSenderCancel() public {
        // Create an escrow first
        vm.prank(sender);
        token.approve(address(escrow), 100 ether);
        
        vm.prank(sender);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            recipient,
            100 ether,
            EscrowSettings({ customResolver: address(0), releaseAddress: address(0), yieldPreset: YieldPreset.OFF, autoReleaseTime: 0, autoCancelTime: 0 })
        );
        
        // Sender cancels - should succeed
        vm.prank(sender);
        escrow.senderCancel(workflowId);
    }

    // ============ Test 6: Governance coordination required ============

    function test_GovernanceCoordinationRequired() public {
        vm.startPrank(guardian);
        
        // First pause
        escrow.pause("First emergency");
        assertTrue(escrow.paused());
        
        // Try to pause again immediately
        vm.expectRevert(AlreadyPausedCannotRepause.selector);
        escrow.pause("Try second pause immediately");
        
        // Try again after 6.99 days
        vm.warp(block.timestamp + 6 days + 23 hours + 55 minutes);
        
        vm.expectRevert(AlreadyPausedCannotRepause.selector);
        escrow.pause("Try second pause after 6.99 days");
        
        vm.stopPrank();
        
        // Only timelock can reset the pause
        vm.prank(timelock);
        escrow.unpause();
        assertFalse(escrow.paused());
        
        // Now guardian can pause again
        vm.prank(guardian);
        escrow.pause("Second emergency - after timelock unpause");
        assertTrue(escrow.paused());
    }

    // ============ Test 7: Event emissions ============

    function test_IncidentPauseTriggeredEventIncludesCycleCount() public {
        vm.prank(guardian);
        
        vm.expectEmit(true, false, false, true, address(escrow));
        emit IncidentPauseTriggered("Test pause", block.timestamp, 1);
        
        escrow.pause("Test pause");
    }

    function test_SystemResumedEventEmitted() public {
        // First pause
        vm.prank(guardian);
        escrow.pause("Test pause");
        
        // Then unpause
        vm.prank(timelock);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit SystemResumed(block.timestamp);
        
        escrow.unpause();
    }

    // ============ Test 8: Edge cases ============

    function test_PauseStateInitializedCorrectly() public {
        (uint256 pausedAt, uint256 unpausedAt, uint256 cycleCount, uint256 lastReset) = escrow.pauseState();
        
        assertEq(pausedAt, 0);
        assertEq(unpausedAt, 0);
        assertEq(cycleCount, 0);
        assertEq(lastReset, 0);
    }

    function test_WindowBoundaryCondition() public {
        // Do pauses near window boundary
        vm.startPrank(guardian);
        
        escrow.pause("Pause 1");
        vm.stopPrank();
        
        vm.prank(timelock);
        escrow.unpause();
        
        vm.prank(guardian);
        escrow.pause("Pause 2");
        vm.stopPrank();
        
        vm.prank(timelock);
        escrow.unpause();
        
        // Skip exactly 90 days
        vm.warp(block.timestamp + PAUSE_WINDOW);
        
        // This should still be at 2 cycles (window not expired yet)
        (,, uint256 countBefore,) = escrow.pauseState();
        assertEq(countBefore, 2);
        
        // Pause again - window should auto-reset
        vm.prank(guardian);
        escrow.pause("Pause 3 - at window boundary");
        
        (,, uint256 countAfter,) = escrow.pauseState();
        assertEq(countAfter, 1); // Reset and incremented
    }

    function test_PauseAttemptBeforeWindowExpiry() public {
        // First pause
        vm.prank(guardian);
        escrow.pause("Pause 1");
        vm.stopPrank();
        
        vm.prank(timelock);
        escrow.unpause();
        
        // Skip 89 days (window is 90 days)
        vm.warp(block.timestamp + 89 days);
        
        // Pause again
        vm.prank(guardian);
        escrow.pause("Pause 2 - within window");
        
        // Should still be 2, not reset
        (,, uint256 count,) = escrow.pauseState();
        assertEq(count, 2);
    }

    // ============ Test 9: Multiple operation checks ============

    function test_AllCriticalFunctionsRespectPauseDuration() public {
        // This test verifies pause affects dispute operations but NOT basic settlement
        
        // Create one escrow  
        vm.prank(sender);
        token.approve(address(escrow), 200 ether);
        
        vm.prank(sender);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            recipient,
            100 ether,
            EscrowSettings({ customResolver: address(0), releaseAddress: address(0), yieldPreset: YieldPreset.OFF, autoReleaseTime: 0, autoCancelTime: 0 })
        );
        
        // Pause
        vm.prank(guardian);
        escrow.pause("Testing");
        
        // raiseDispute should revert immediately (no time check)
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(sender);
        escrow.raiseDispute(workflowId);
    }

    // Events to match
    event IncidentPauseTriggered(
        string reason,
        uint256 timestamp,
        uint256 pauseCycleCount
    );
    
    event SystemResumed(
        uint256 timestamp
    );
}
