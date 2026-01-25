// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';

contract OpsCoverageTest is Test {
    CreateOps public createOps;
    YieldOps public yieldOps;
    SettlementOps public settlementOps;
    DisputeOps public disputeOps;
    ERC20Mock public token;

    address public owner;
    address public timelock;
    address public guardian;
    address public escrowContract;
    address public unauthorized;
    address public feeRecipient;

    function setUp() public {
        owner = address(this);
        timelock = address(0x1);
        guardian = address(0x2);
        escrowContract = address(0x3);
        unauthorized = address(0x4);
        feeRecipient = address(0x5);

        // Deploy Ops contracts
        createOps = new CreateOps(owner);
        yieldOps = new YieldOps(owner);
        settlementOps = new SettlementOps(owner);
        disputeOps = new DisputeOps(owner);

        token = new ERC20Mock('Test Token', 'TEST', owner, 10000e18);

        // Setup roles for CreateOps
        createOps.grantRole(createOps.ROLE_TIMELOCK(), timelock);
        createOps.grantRole(createOps.ROLE_GUARDIAN(), guardian);
        
        // Setup roles for YieldOps
        yieldOps.grantRole(yieldOps.ROLE_TIMELOCK(), timelock);
        yieldOps.grantRole(yieldOps.ROLE_GUARDIAN(), guardian);

        // Setup roles for SettlementOps
        settlementOps.grantRole(settlementOps.ROLE_TIMELOCK(), timelock);

        // Setup roles for DisputeOps
        disputeOps.grantRole(disputeOps.ROLE_TIMELOCK(), timelock);
    }

    // ============ CreateOps Tests ============

    function test_CreateOps_pauseYieldDeposits_Guardian() public {
        vm.prank(guardian);
        createOps.pauseYieldDeposits("Emergency");
        assertTrue(createOps.yieldDepositsPaused());
    }

    function test_CreateOps_pauseYieldDeposits_Timelock() public {
        vm.prank(timelock);
        createOps.pauseYieldDeposits("Maintenance");
        assertTrue(createOps.yieldDepositsPaused());
    }

    function test_CreateOps_pauseYieldDeposits_Unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(CreateOps.NotAuthorized.selector, unauthorized));
        createOps.pauseYieldDeposits("Hacking");
    }

    function test_CreateOps_pauseYieldDeposits_AlreadyPaused() public {
        vm.prank(guardian);
        createOps.pauseYieldDeposits("Emergency");
        
        vm.prank(guardian);
        vm.expectRevert(CreateOps.AlreadyPaused.selector);
        createOps.pauseYieldDeposits("Emergency 2");
    }

    function test_CreateOps_resumeYieldDeposits_Timelock() public {
        vm.prank(guardian);
        createOps.pauseYieldDeposits("Emergency");

        vm.prank(timelock);
        createOps.resumeYieldDeposits();
        assertFalse(createOps.yieldDepositsPaused());
    }

    function test_CreateOps_resumeYieldDeposits_Guardian_Reverts() public {
        vm.prank(guardian);
        createOps.pauseYieldDeposits("Emergency");

        // Guardian cannot resume (down-only)
        vm.prank(guardian);
        // Standard AccessControl error
        vm.expectRevert(); 
        createOps.resumeYieldDeposits();
    }

    function test_CreateOps_resumeYieldDeposits_NotPaused() public {
        vm.prank(timelock);
        vm.expectRevert(CreateOps.NotPaused.selector);
        createOps.resumeYieldDeposits();
    }

    function test_CreateOps_registerEscrowContract() public {
        vm.prank(timelock);
        createOps.registerEscrowContract(escrowContract);
        assertTrue(createOps.hasRole(createOps.ROLE_ESCROW_CONTRACT(), escrowContract));
    }

    function test_CreateOps_registerEscrowContract_Unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        createOps.registerEscrowContract(escrowContract);
    }

    function test_CreateOps_computeEscrowCreation_RespectsPause() public {
        // Register escrow contract
        vm.prank(timelock);
        createOps.registerEscrowContract(escrowContract);

        // Pause deposits
        vm.prank(guardian);
        createOps.pauseYieldDeposits("Emergency");

        // Prepare input data
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER, // User wants yield
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Call computeEscrowCreation
        vm.prank(escrowContract);
        CreateOps.CreateResult memory result = createOps.computeEscrowCreation(
            address(token),
            address(0x123), // to
            address(0x456), // from
            1000, // amount
            settings,
            100, // fee
            1, // workflowId
            address(0) // resolutionModule
        );

        // Verify yield is disabled despite user setting
        assertTrue(result.yieldEnabled); // Input setting remains true
        assertFalse(result.shouldDepositYield); // But action is false due to pause
    }

    function test_CreateOps_computeEscrowCreation_ResolverQuery() public {
        vm.prank(timelock);
        createOps.registerEscrowContract(escrowContract);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        MockResolutionModule resMock = new MockResolutionModule();
        
        vm.prank(escrowContract);
        CreateOps.CreateResult memory result = createOps.computeEscrowCreation(
            address(token),
            address(0x1),
            address(0x2),
            1000,
            settings,
            100,
            1,
            address(resMock)
        );

        assertEq(result.resolver, address(0x123));
    }

    function test_CreateOps_computeEscrowCreation_ResolverFailure() public {
        vm.prank(timelock);
        createOps.registerEscrowContract(escrowContract);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        MockResolutionModule resMock = new MockResolutionModule();
        resMock.setRevert(true);
        
        vm.prank(escrowContract);
        CreateOps.CreateResult memory result = createOps.computeEscrowCreation(
            address(token),
            address(0x1),
            address(0x2),
            1000,
            settings,
            100,
            1,
            address(resMock)
        );

        assertEq(result.resolver, address(0));
    }

    function test_CreateOps_computeEscrowCreation_EOAResolver() public {
        vm.prank(timelock);
        createOps.registerEscrowContract(escrowContract);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.prank(escrowContract);
        CreateOps.CreateResult memory result = createOps.computeEscrowCreation(
            address(token),
            address(0x1),
            address(0x2),
            1000,
            settings,
            100,
            1,
            address(0xDEAD) // EOA
        );

        assertEq(result.resolver, address(0));
    }

    // ============ YieldOps Tests ============

    function test_YieldOps_handleYield_WithdrawalFailed() public {
        mockGen = new MockYieldGenerationModule();
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        // Success = false from module
        mockGen.setWithdrawResult(false, 0, 0);

        vm.prank(escrowContract);
        YieldOps.YieldResult memory result = yieldOps.handleYield(
            IYieldGenerationModule(address(mockGen)),
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            1000,
            0,
            feeRecipient,
            ""
        );

        assertFalse(result.success, "Should fail when module returns false");
        assertTrue(bytes(result.failureReason).length > 0, "Should have failure reason");
        assertEq(result.actualAmount, 1000, "Should return original amount"); // Falls back to original amount
        assertEq(result.yield, 0, "Should have no yield");
    }

    function test_YieldOps_distributeWithdrawnYield_ProtocolFee() public {
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        uint256 earned = 100;
        token.mint(address(yieldOps), earned);

        vm.prank(escrowContract);
        YieldOps.DistributionResult memory result = yieldOps.distributeWithdrawnYield(
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            earned,
            1000, // 10% protocol fee
            feeRecipient,
            ""
        );

        assertTrue(result.success);
        assertEq(result.distributedAmount, 90); // 90 after 10% fee
        assertEq(bytes(result.failureReason).length, 0, "Should have no failure reason");
        // feeRecipient should have: 10 (protocol fee) + 90 (distributed amount since no distModule) = 100
        assertEq(token.balanceOf(feeRecipient), 100);
    }

    function test_YieldOps_recoverTokens_Guardian() public {
        // Send tokens to YieldOps
        token.mint(address(yieldOps), 1000e18);
        
        uint256 balanceBefore = token.balanceOf(guardian);
        
        vm.prank(guardian);
        yieldOps.recoverTokens(address(token), guardian, 1000e18);
        
        assertEq(token.balanceOf(guardian), balanceBefore + 1000e18);
        assertEq(token.balanceOf(address(yieldOps)), 0);
    }

    function test_YieldOps_recoverTokens_Unauthorized() public {
        token.mint(address(yieldOps), 1000e18);
        
        vm.prank(unauthorized);
        vm.expectRevert(); // AccessControl error
        yieldOps.recoverTokens(address(token), unauthorized, 1000e18);
    }

    function test_YieldOps_recoverETH_Guardian() public {
        // Send ETH to YieldOps (needs to handle receive/fallback or we force send)
        vm.deal(address(yieldOps), 1 ether);
        
        uint256 balanceBefore = guardian.balance;
        
        vm.prank(guardian);
        yieldOps.recoverTokens(address(0), guardian, 1 ether);
        
        assertEq(guardian.balance, balanceBefore + 1 ether);
        assertEq(address(yieldOps).balance, 0);
    }

    function test_YieldOps_registerEscrowContract_Invalid() public {
        vm.prank(timelock);
        vm.expectRevert();
        yieldOps.registerEscrowContract(address(0));
    }

    function test_YieldOps_handleYield_NoYieldGenerated() public {
        mockGen = new MockYieldGenerationModule();
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        // Withdrawal succeeds but no yield generated
        mockGen.setWithdrawResult(true, 1000, 0);

        vm.prank(escrowContract);
        YieldOps.YieldResult memory result = yieldOps.handleYield(
            IYieldGenerationModule(address(mockGen)),
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            1000,
            0,
            feeRecipient,
            ""
        );

        assertTrue(result.success);
        assertEq(result.yield, 0);
        assertEq(result.actualAmount, 1000);
        assertEq(result.yieldDistributed, 0);
    }

    // ============ SettlementOps Tests ============

    function test_SettlementOps_registerEscrowContract() public {
        vm.prank(timelock);
        settlementOps.registerEscrowContract(escrowContract);
        assertTrue(settlementOps.hasRole(settlementOps.ROLE_ESCROW_CONTRACT(), escrowContract));
    }

    function test_SettlementOps_computeResolutionExecution_AccessControl() public {
        // Unauthorized
        vm.prank(unauthorized);
        vm.expectRevert();
        settlementOps.computeResolutionExecution(
            address(0), 
            1, 
            true, 
            TimeoutConfig(0, 0, 0, 0)
        );

        // Authorized
        vm.prank(timelock);
        settlementOps.registerEscrowContract(escrowContract);

        vm.prank(escrowContract);
        // Should success (even with dummy data, it returns a result)
        settlementOps.computeResolutionExecution(
            address(0), 
            1, 
            true, 
            TimeoutConfig(0, 0, 0, 0)
        );
    }

    // ============ DisputeOps Tests ============

    function test_DisputeOps_registerEscrowContract() public {
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);
        assertTrue(disputeOps.hasRole(disputeOps.ROLE_ESCROW_CONTRACT(), escrowContract));
    }

    function test_DisputeOps_computeEscalation_AccessControl() public {
        // Unauthorized
        vm.prank(unauthorized);
        vm.expectRevert();
        disputeOps.computeEscalation(
            address(0),
            1,
            address(0),
            address(0),
            address(0),
            address(0),
            0,
            EscrowState.DISPUTED
        );

        // Authorized
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        vm.prank(escrowContract);
        // Should execute (result.success might be false due to inputs, but call shouldn't revert with access control)
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(0),
            1,
            address(0x99), // caller (not participant)
            address(0x1), // from
            address(0x2), // to
            address(0),
            0,
            EscrowState.DISPUTED
        );
        assertFalse(result.success); // Failure expected due to dummy inputs
        assertEq(result.failureReason, 'Caller not participant'); // First check in logic
    }

    // ============ DisputeOps Extended Tests ============

    MockResolutionModule public mockModule;

    function test_DisputeOps_computeEscalation_Success() public {
        mockModule = new MockResolutionModule();
        
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        address from = address(0x1);
        address to = address(0x2);
        address caller = from;
        address nextResolver = address(0x999);
        uint256 fee = 0.1 ether;

        // Configure mock
        mockModule.setEscalation(true, nextResolver, fee);
        mockModule.setExecution(true, nextResolver, 1);
        
        // IMPORTANT: Must have a valid decision to allow appeal
        // Decision 1 (RELEASE) means recipient won, so sender (from) can appeal
        mockModule.setDecision(1); 

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(mockModule),
            1,
            caller,
            from,
            to,
            address(token),
            1000,
            EscrowState.DISPUTED
        );

        if (!result.success) {
            emit log_named_string("Failure Reason", result.failureReason);
        }
        assertTrue(result.success);
        assertEq(result.newResolver, nextResolver);
        assertEq(result.newLevel, 1);
        assertEq(result.escalationFee, fee);
    }

    function test_DisputeOps_computeEscalation_WrongState() public {
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(0),
            1,
            address(0x1),
            address(0x1),
            address(0x2),
            address(token),
            1000,
            EscrowState.PENDING // Wrong state
        );

        assertFalse(result.success);
        assertEq(result.failureReason, 'Not in disputed state');
    }

    function test_DisputeOps_computeEscalation_AppealRights() public {
        mockModule = new MockResolutionModule();
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        address from = address(0x1);
        address to = address(0x2);

        // Case 1: RELEASE decision (Recipient won), Sender should be able to appeal
        mockModule.setDecision(1); // RELEASE
        mockModule.setEscalation(true, address(0x999), 0);
        mockModule.setExecution(true, address(0x999), 1);

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory resultSender = disputeOps.computeEscalation(
            address(mockModule),
            1,
            from, // Sender appealing
            from,
            to,
            address(token),
            1000,
            EscrowState.DISPUTED
        );
        assertTrue(resultSender.success);

        // Case 2: RELEASE decision, Recipient tries to appeal (should fail)
        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory resultRecipient = disputeOps.computeEscalation(
            address(mockModule),
            1,
            to, // Recipient appealing
            from,
            to,
            address(token),
            1000,
            EscrowState.DISPUTED
        );
        assertFalse(resultRecipient.success);
        assertEq(resultRecipient.failureReason, 'Only sender can appeal RELEASE decision');

        // Case 3: CANCEL decision (Sender won), Recipient should be able to appeal
        mockModule.setDecision(2); // CANCEL
        
        vm.prank(escrowContract);
        resultRecipient = disputeOps.computeEscalation(
            address(mockModule),
            1,
            to, // Recipient appealing
            from,
            to,
            address(token),
            1000,
            EscrowState.DISPUTED
        );
        assertTrue(resultRecipient.success);

        // Case 4: CANCEL decision, Sender tries to appeal (should fail)
        vm.prank(escrowContract);
        resultSender = disputeOps.computeEscalation(
            address(mockModule),
            1,
            from, // Sender appealing
            from,
            to,
            address(token),
            1000,
            EscrowState.DISPUTED
        );
        assertFalse(resultSender.success);
        assertEq(resultSender.failureReason, 'Only recipient can appeal CANCEL decision');
    }

    function test_DisputeOps_computeEscalation_ModuleRejection() public {
        mockModule = new MockResolutionModule();
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        // Set valid decision so it proceeds to canEscalate
        mockModule.setDecision(1); // RELEASE
        address caller = address(0x1); // Sender (from) matches 0x1 below

        // Module says no escalation
        mockModule.setEscalation(false, address(0), 0);

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(mockModule),
            1,
            caller, // matches from
            address(0x1), // from
            address(0x2), // to
            address(token),
            1000,
            EscrowState.DISPUTED
        );

        assertFalse(result.success);
        assertEq(result.failureReason, 'Escalation not allowed');
    }

    function test_DisputeOps_computeEscalation_GetLevelFailed() public {
        mockModule = new MockResolutionModule();
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        mockModule.setRevert(true); // Fails getDisputeResolver

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(mockModule),
            1,
            address(0x1),
            address(0x1),
            address(0x2),
            address(token),
            1000,
            EscrowState.DISPUTED
        );

        assertFalse(result.success);
        assertEq(result.failureReason, 'Failed to get current level');
    }

    function test_DisputeOps_computeEscalation_ExecFailed() public {
        mockModule = new MockResolutionModule();
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        mockModule.setDecision(1);
        mockModule.setEscalation(true, address(0x999), 0);
        mockModule.setExecution(false, address(0), 0); // Exec fails

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(mockModule),
            1,
            address(0x1),
            address(0x1),
            address(0x2),
            address(token),
            1000,
            EscrowState.DISPUTED
        );

        assertFalse(result.success);
        assertEq(result.failureReason, 'Module rejected escalation');
    }

    function test_DisputeOps_computeEscalation_ExecZero() public {
        mockModule = new MockResolutionModule();
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        mockModule.setDecision(1);
        mockModule.setEscalation(true, address(0x999), 0);
        mockModule.setExecution(true, address(0), 0); // Exec success but zero addr

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(mockModule),
            1,
            address(0x1),
            address(0x1),
            address(0x2),
            address(token),
            1000,
            EscrowState.DISPUTED
        );

        assertFalse(result.success);
        assertEq(result.failureReason, 'Module returned zero address');
    }

    function test_DisputeOps_encodeEscrowData() public {
        bytes memory data = disputeOps.encodeEscrowData(
            address(token),
            address(0x1),
            address(0x2),
            1000
        );
        bytes memory expected = abi.encode(address(token), address(0x1), address(0x2), uint256(1000));
        assertEq(data, expected);
    }

    function test_DisputeOps_computeEscalation_ModuleNotConfigured() public {
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(0), // No resolution module
            1,
            address(0x1),
            address(0x1),
            address(0x2),
            address(token),
            1000,
            EscrowState.DISPUTED
        );

        assertFalse(result.success);
        assertEq(result.failureReason, 'Resolution module not configured');
    }

    function test_DisputeOps_computeEscalation_NoDecision() public {
        mockModule = new MockResolutionModule();
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        // Set decision to 0 (NONE)
        mockModule.setDecision(0);

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(mockModule),
            1,
            address(0x1), // Sender
            address(0x1),
            address(0x2),
            address(token),
            1000,
            EscrowState.DISPUTED
        );

        assertFalse(result.success);
        assertEq(result.failureReason, 'No decision to appeal');
    }

    function test_DisputeOps_computeEscalation_CanEscalateCallFails() public {
        mockModule = new MockResolutionModule();
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        // Set valid decision
        mockModule.setDecision(1); // RELEASE
        
        // Make canEscalate revert by setting revert flag
        // But we need to make it fail only for canEscalate, not getDisputeResolver
        // Looking at mock, shouldRevert affects both. We need a different approach.
        // Actually, the mock's canEscalate will revert if shouldRevert is true
        // But getDisputeResolver also reverts. 
        // For this test, we can't easily trigger only canEscalate failure with current mock
        // Let's create a scenario where canEscalate tries to call but fails
        
        // Actually, looking at DisputeOps.sol line 177-179, the catch block sets
        // 'Failed to check escalation eligibility'. This happens when canEscalate() reverts.
        // We need getDisputeResolver to succeed but canEscalate to fail.
        
        // Create a new mock for this specific case
        MockResolutionModuleCanEscalateFails mockSpecial = new MockResolutionModuleCanEscalateFails();
        mockSpecial.setDecision(1);

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(mockSpecial),
            1,
            address(0x1), // Sender
            address(0x1),
            address(0x2),
            address(token),
            1000,
            EscrowState.DISPUTED
        );

        assertFalse(result.success);
        assertEq(result.failureReason, 'Failed to check escalation eligibility');
    }

    function test_DisputeOps_computeEscalation_ExecuteEscalationCallFails() public {
        mockModule = new MockResolutionModule();
        vm.prank(timelock);
        disputeOps.registerEscrowContract(escrowContract);

        // Set valid decision and canEscalate success
        mockModule.setDecision(1);
        mockModule.setEscalation(true, address(0x999), 0);
        
        // Create a mock that will revert on executeEscalation
        MockResolutionModuleExecuteFails mockSpecial = new MockResolutionModuleExecuteFails();
        mockSpecial.setDecision(1);
        mockSpecial.setEscalation(true, address(0x999), 0);

        vm.prank(escrowContract);
        DisputeOps.EscalationResult memory result = disputeOps.computeEscalation(
            address(mockSpecial),
            1,
            address(0x1), // Sender
            address(0x1),
            address(0x2),
            address(token),
            1000,
            EscrowState.DISPUTED
        );

        assertFalse(result.success);
        assertEq(result.failureReason, 'Module escalation call failed');
    }


    // ============ CreateOps Extended Tests ============

    function test_CreateOps_computeEscrowCreation_InvalidInputs() public {
        vm.prank(timelock);
        createOps.registerEscrowContract(escrowContract);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.prank(escrowContract);
        // Invalid Token
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector, ADDR_TOKEN, address(0)));
        createOps.computeEscrowCreation(
            address(0), 
            address(0x1), 
            address(0x2), 
            100, 
            settings, 
            100, 
            1, 
            address(0)
        );

        vm.prank(escrowContract);
        // Invalid Amount
        vm.expectRevert(AmountZero.selector);
        createOps.computeEscrowCreation(
            address(token), 
            address(0x1), 
            address(0x2), 
            0, 
            settings, 
            100, 
            1, 
            address(0)
        );
    }

    function test_CreateOps_computeEscrowCreation_FeeCalculation() public {
        vm.prank(timelock);
        createOps.registerEscrowContract(escrowContract);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        uint256 amount = 10000;
        uint256 feeBps = 500; // 5%

        vm.prank(escrowContract);
        CreateOps.CreateResult memory result = createOps.computeEscrowCreation(
            address(token), 
            address(0x1), 
            address(0x2), 
            amount, 
            settings, 
            feeBps, 
            1, 
            address(0)
        );

        assertEq(result.fee, 500); // 5% of 10000
        assertEq(result.amountAfterFee, 9500);
    }

    // ============ YieldOps Extended Tests ============

    MockYieldGenerationModule public mockGen;
    MockYieldDistributionModule public mockDist;

    function test_YieldOps_handleYield_Success() public {
        mockGen = new MockYieldGenerationModule();
        
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        // Setup yield behavior
        uint256 original = 1000;
        uint256 earned = 100;
        uint256 total = 1100;
        
        mockGen.setWithdrawResult(true, total, earned);

        vm.prank(escrowContract);
        YieldOps.YieldResult memory result = yieldOps.handleYield(
            IYieldGenerationModule(address(mockGen)),
            IYieldDistributionModule(address(0)), // Not used in handleYield anymore
            1,
            address(token),
            original,
            0,
            feeRecipient,
            ""
        );

        // handleYield ONLY withdraws, does NOT distribute
        // Distribution must be done separately via distributeWithdrawnYield
        assertTrue(result.success);
        assertEq(result.yield, earned);
        assertEq(result.actualAmount, total);
        assertEq(result.yieldDistributed, 0); // No distribution in handleYield
    }

    function test_YieldOps_handleYield_GenFailure() public {
        mockGen = new MockYieldGenerationModule();
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        mockGen.setRevert(true);

        vm.prank(escrowContract);
        // Should not revert, but return failure with reason
        YieldOps.YieldResult memory result = yieldOps.handleYield(
            IYieldGenerationModule(address(mockGen)),
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            1000,
            0,
            feeRecipient,
            ""
        );

        assertFalse(result.success, "Should fail");
        assertTrue(bytes(result.failureReason).length > 0, "Should have failure reason");
        assertEq(result.yield, 0, "Should have no yield");
        assertEq(result.actualAmount, 1000, "Should return original amount");
    }

    function test_YieldOps_distributeWithdrawnYield_DistFailure() public {
        mockDist = new MockYieldDistributionModule();
        
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        uint256 earned = 100;
        token.mint(address(yieldOps), earned);

        mockDist.setRevert(true);

        vm.prank(escrowContract);
        YieldOps.DistributionResult memory result = yieldOps.distributeWithdrawnYield(
            IYieldDistributionModule(address(mockDist)),
            1,
            address(token),
            earned,
            0,
            feeRecipient,
            ""
        );

        // On failure, success = false, but yield is sent to feeRecipient as fallback
        assertFalse(result.success, "Should fail"); 
        assertEq(result.distributedAmount, earned, "Should distribute to fallback"); // Fallback amount
        assertTrue(bytes(result.failureReason).length > 0, "Should have failure reason");
        
        // Verify feeRecipient got tokens
        assertEq(token.balanceOf(feeRecipient), earned);
    }

    function test_YieldOps_distributeWithdrawnYield_NoDistModule() public {
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        uint256 earned = 100;
        token.mint(address(yieldOps), earned);

        vm.prank(escrowContract);
        YieldOps.DistributionResult memory result = yieldOps.distributeWithdrawnYield(
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            earned,
            0,
            feeRecipient,
            ""
        );

        // No distribution module: yield goes to feeRecipient as fallback
        assertTrue(result.success, "Should succeed with fallback");
        assertEq(result.distributedAmount, earned, "Should distribute full amount");
        assertEq(bytes(result.failureReason).length, 0, "Should have no failure reason");
        assertEq(token.balanceOf(feeRecipient), earned);
    }

    function test_YieldOps_distributeWithdrawnYield_FeeRecipientCannotBeZero() public {
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        uint256 earned = 100;
        token.mint(address(yieldOps), earned);

        vm.prank(escrowContract);
        vm.expectRevert(YieldOps.FeeRecipientCannotBeZero.selector);
        yieldOps.distributeWithdrawnYield(
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            earned,
            1000, // 10% protocol fee - requires feeRecipient
            address(0), // Zero address for feeRecipient
            ""
        );
    }

    function test_YieldOps_distributeWithdrawnYield_ProtocolFeeExceedsMaximum() public {
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        uint256 earned = 100;
        token.mint(address(yieldOps), earned);

        vm.prank(escrowContract);
        vm.expectRevert(abi.encodeWithSelector(
            YieldOps.ProtocolFeeExceedsMaximum.selector,
            3001,
            3000
        ));
        yieldOps.distributeWithdrawnYield(
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            earned,
            3001, // 30.01% protocol fee - exceeds 30% maximum
            feeRecipient,
            ""
        );
    }

    function test_YieldOps_distributeWithdrawnYield_NoFeeRecipientNoDistModule() public {
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        uint256 earned = 100;
        token.mint(address(yieldOps), earned);

        vm.prank(escrowContract);
        YieldOps.DistributionResult memory result = yieldOps.distributeWithdrawnYield(
            IYieldDistributionModule(address(0)), // No distribution module
            1,
            address(token),
            earned,
            0,
            address(0), // No fee recipient
            ""
        );

        // Yield should stay in YieldOps - returns success but 0 distributed
        // This is a warning scenario tracked by failureReason
        assertTrue(result.success, "Should succeed (yield stays in contract)");
        assertEq(result.distributedAmount, 0, "Should not distribute");
        assertTrue(bytes(result.failureReason).length > 0, "Should have failure reason explaining yield stayed in contract");
        // Yield stays in contract
        assertEq(token.balanceOf(address(yieldOps)), earned);
    }

    function test_YieldOps_handleYield_WithdrawalReturnsFalse() public {
        MockYieldGenerationModule mockGen = new MockYieldGenerationModule();
        mockGen.setWithdrawSuccess(false); // Make it return false
        
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        vm.prank(escrowContract);
        YieldOps.YieldResult memory result = yieldOps.handleYield(
            IYieldGenerationModule(address(mockGen)),
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            1000,
            0,
            feeRecipient,
            ""
        );

        // Should fail with appropriate reason
        assertFalse(result.success, "Should fail");
        assertTrue(bytes(result.failureReason).length > 0, "Should have failure reason");
        assertEq(result.yield, 0, "Should have no yield");
    }

    function test_YieldOps_handleYield_WithdrawalRevert() public {
        MockYieldGenerationModule mockGen = new MockYieldGenerationModule();
        mockGen.setRevert(true); // Make it revert
        
        vm.prank(timelock);
        yieldOps.registerEscrowContract(escrowContract);

        vm.prank(escrowContract);
        YieldOps.YieldResult memory result = yieldOps.handleYield(
            IYieldGenerationModule(address(mockGen)),
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            1000,
            0,
            feeRecipient,
            ""
        );

        // Should fail with appropriate reason
        assertFalse(result.success, "Should fail");
        assertTrue(bytes(result.failureReason).length > 0, "Should have failure reason");
        assertEq(result.yield, 0, "Should have no yield");
    }

    function test_YieldOps_distributeYieldInternal_AccessControl() public {
        // distributeYieldInternal is public but has check: msg.sender == address(this)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldOps.InternalOnly.selector, owner));
        yieldOps._distributeYieldInternal(
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            100,
            ""
        );
    }

    // ============ SettlementOps Extended Tests ============

    function test_SettlementOps_computePendingSettlementExecution() public {
        vm.prank(timelock);
        settlementOps.registerEscrowContract(escrowContract);

        SettlementOps.SettlementPendingSettlement memory pending;
        
        vm.prank(escrowContract);
        // Not exists
        pending.exists = false;
        (bool canExecute, ) = settlementOps.computePendingSettlementExecution(1, pending, EscrowState.DISPUTED);
        assertFalse(canExecute);

        // Exists, window not expired
        pending.exists = true;
        pending.appealDeadline = block.timestamp + 100;
        vm.prank(escrowContract);
        (bool canExecute2, ) = settlementOps.computePendingSettlementExecution(1, pending, EscrowState.DISPUTED);
        assertFalse(canExecute2);

        // Exists, window expired, Wrong state
        vm.warp(block.timestamp + 200);
        vm.prank(escrowContract);
        (bool canExecute3, ) = settlementOps.computePendingSettlementExecution(1, pending, EscrowState.PENDING);
        assertFalse(canExecute3);

        // Success
        vm.prank(escrowContract);
        bool isRelease;
        bool canExecuteSuccess;
        (canExecuteSuccess, isRelease) = settlementOps.computePendingSettlementExecution(1, pending, EscrowState.DISPUTED);
        assertTrue(canExecuteSuccess);
        assertEq(isRelease, pending.isRelease);
    }

    function test_SettlementOps_computeTimedActions() public {
        vm.prank(timelock);
        settlementOps.registerEscrowContract(escrowContract);

        EscrowTransfer memory et;
        SettlementOps.SettlementPendingSettlement memory pending;
        TimeoutConfig memory config;

        // 1. Pending settlement ready
        et.escrowState = EscrowState.DISPUTED;
        pending.exists = true;
        pending.appealDeadline = block.timestamp; // Ready now
        pending.isRelease = true;
        
        vm.prank(escrowContract);
        (uint8 action, bool isRelease) = settlementOps.computeTimedActions(1, et, pending, config);
        assertEq(action, 3); // Action 3 = Pending Settlement
        assertTrue(isRelease);

        // 2. Not Pending State (and no pending settlement ready)
        pending.exists = false;
        et.escrowState = EscrowState.DISPUTED; // Not PENDING
        
        vm.prank(escrowContract);
        (action, ) = settlementOps.computeTimedActions(1, et, pending, config);
        assertEq(action, 0);

        // 3. Auto Release
        et.escrowState = EscrowState.PENDING;
        et.autoReleaseTime = uint64(block.timestamp); // Ready now
        et.autoCancelTime = 0;

        vm.prank(escrowContract);
        (action, isRelease) = settlementOps.computeTimedActions(1, et, pending, config);
        assertEq(action, 1); // Auto Release
        assertTrue(isRelease);

        // 4. Auto Cancel
        et.autoReleaseTime = 0;
        et.autoCancelTime = uint64(block.timestamp);

        vm.prank(escrowContract);
        (action, isRelease) = settlementOps.computeTimedActions(1, et, pending, config);
        assertEq(action, 2); // Auto Cancel
        assertFalse(isRelease);
    }

    function test_SettlementOps_computeResolutionExecution_InvalidModule() public {
        vm.prank(timelock);
        settlementOps.registerEscrowContract(escrowContract);

        TimeoutConfig memory config;
        config.appealWindowDuration = 1 days;

        vm.prank(escrowContract);
        // Address 0 module
        SettlementOps.ResolutionResult memory result = settlementOps.computeResolutionExecution(
            address(0),
            1,
            true,
            config
        );
        // Should fallback to global config
        assertEq(result.appealDeadline, block.timestamp + 1 days);
        assertFalse(result.shouldExecute);

        // Invalid module (no code)
        vm.prank(escrowContract);
        result = settlementOps.computeResolutionExecution(
            address(0x999), // Random address with no code
            1,
            true,
            config
        );
        assertEq(result.appealDeadline, block.timestamp + 1 days);
    }

    // ============ DisputeOps Extended Tests ============

    function test_DisputeOps_validateEscalationFee() public {
        (bool valid, uint256 excess) = disputeOps.validateEscalationFee(100, 50);
        assertFalse(valid);
        assertEq(excess, 0);

        (valid, excess) = disputeOps.validateEscalationFee(100, 100);
        assertTrue(valid);
        assertEq(excess, 0);

        (valid, excess) = disputeOps.validateEscalationFee(100, 150);
        assertTrue(valid);
        assertEq(excess, 50);
    }
}

// ============ Mocks ============

contract MockYieldGenerationModule is IYieldGenerationModule {
    bool public shouldRevert;
    bool public success;
    uint256 public actual;
    uint256 public yield;

    function setRevert(bool _r) external { shouldRevert = _r; }
    function setWithdrawSuccess(bool _s) external { success = _s; }
    function setWithdrawResult(bool _s, uint256 _a, uint256 _y) external {
        success = _s;
        actual = _a;
        yield = _y;
    }

    function withdrawWithYield(uint256, address, uint256) external view returns (bool, uint256, uint256) {
        if (shouldRevert) revert("Gen Fail");
        return (success, actual, yield);
    }

    function depositForYield(uint256, address, uint256) external pure returns (bool, uint256) { return (true, 0); }
    function calculateYield(uint256, address) external pure returns (uint256) { return 0; }
    function isTokenSupported(address) external pure returns (bool) { return true; }
    function getApprovalTarget(address) external pure returns (address) { return address(0); }
    function moduleName() external pure returns (string memory) { return "MockGen"; }
    function moduleVersion() external pure returns (string memory) { return "1.0"; }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
    function getAavePoolAddress() external pure returns (address) { return address(0); }
    function getATokenAddress(address) external pure returns (address) { return address(0); }
}

contract MockYieldDistributionModule is IYieldDistributionModule {
    bool public shouldRevert;
    bool public success;
    uint256 public distributed;

    function setRevert(bool _r) external { shouldRevert = _r; }
    function setDistributeResult(bool _s, uint256 _d) external {
        success = _s;
        distributed = _d;
    }

    function distributeYield(uint256, address, uint256, bytes calldata) external view returns (bool, uint256) {
        if (shouldRevert) revert("Dist Fail");
        return (success, distributed);
    }

    function moduleName() external pure returns (string memory) { return "MockDist"; }
    function moduleVersion() external pure returns (string memory) { return "1.0"; }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
}

contract MockResolutionModule {
    bool public shouldEscalate;
    address public nextResolver;
    uint256 public escalationFee;
    
    bool public execSuccess;
    address public execNewResolver;
    uint8 public execNewLevel;

    uint8 public decision; // 0=NONE, 1=RELEASE, 2=CANCEL
    bool public shouldRevert;

    function setEscalation(bool _should, address _next, uint256 _fee) external {
        shouldEscalate = _should;
        nextResolver = _next;
        escalationFee = _fee;
    }

    function setExecution(bool _success, address _newResolver, uint8 _newLevel) external {
        execSuccess = _success;
        execNewResolver = _newResolver;
        execNewLevel = _newLevel;
    }

    function setDecision(uint8 _decision) external {
        decision = _decision;
    }

    function setRevert(bool _r) external {
        shouldRevert = _r;
    }

    // IResolutionModule implementation
    function canEscalate(
        uint256,
        uint8,
        bytes calldata
    ) external view returns (bool, address, uint256) {
        if (shouldRevert) revert("Revert");
        return (shouldEscalate, nextResolver, escalationFee);
    }

    function executeEscalation(
        uint256,
        bytes calldata
    ) external view returns (bool, address, uint8) {
        if (shouldRevert) revert("Revert");
        return (execSuccess, execNewResolver, execNewLevel);
    }

    function getDisputeResolver(
        uint256,
        bytes calldata
    ) external view returns (address, uint8) {
        if (shouldRevert) revert("Revert");
        return (address(0x123), 0);
    }

    function getDecisionAtRound(uint256, uint8) external view returns (uint8) {
        if (shouldRevert) revert("Revert");
        return decision;
    }

    function isAuthorizedDisputeResolver(uint256, address, bytes calldata) external pure returns (bool, uint8) {
        return (true, 0);
    }

    function getRequiredAppealBond(uint256, uint8, bytes calldata) external pure returns (uint256, address) {
        return (0, address(0));
    }

    function moduleName() external pure returns (string memory) { return "Mock"; }
    function moduleVersion() external pure returns (string memory) { return "1.0"; }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
}

contract MockResolutionModuleCanEscalateFails {
    uint8 public decision;

    function setDecision(uint8 _decision) external {
        decision = _decision;
    }

    function canEscalate(uint256, uint8, bytes calldata) external pure returns (bool, address, uint256) {
        revert("canEscalate failed");
    }

    function getDisputeResolver(uint256, bytes calldata) external pure returns (address, uint8) {
        return (address(0x123), 0);
    }

    function getDecisionAtRound(uint256, uint8) external view returns (uint8) {
        return decision;
    }

    function executeEscalation(uint256, bytes calldata) external pure returns (bool, address, uint8) {
        return (true, address(0x999), 1);
    }

    function isAuthorizedDisputeResolver(uint256, address, bytes calldata) external pure returns (bool, uint8) {
        return (true, 0);
    }

    function getRequiredAppealBond(uint256, uint8, bytes calldata) external pure returns (uint256, address) {
        return (0, address(0));
    }

    function moduleName() external pure returns (string memory) { return "Mock"; }
    function moduleVersion() external pure returns (string memory) { return "1.0"; }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
}

contract MockResolutionModuleExecuteFails {
    bool public shouldEscalate;
    address public nextResolver;
    uint256 public escalationFee;
    uint8 public decision;

    function setDecision(uint8 _decision) external {
        decision = _decision;
    }

    function setEscalation(bool _should, address _next, uint256 _fee) external {
        shouldEscalate = _should;
        nextResolver = _next;
        escalationFee = _fee;
    }

    function canEscalate(uint256, uint8, bytes calldata) external view returns (bool, address, uint256) {
        return (shouldEscalate, nextResolver, escalationFee);
    }

    function getDisputeResolver(uint256, bytes calldata) external pure returns (address, uint8) {
        return (address(0x123), 0);
    }

    function getDecisionAtRound(uint256, uint8) external view returns (uint8) {
        return decision;
    }

    function executeEscalation(uint256, bytes calldata) external pure returns (bool, address, uint8) {
        revert("executeEscalation failed");
    }

    function isAuthorizedDisputeResolver(uint256, address, bytes calldata) external pure returns (bool, uint8) {
        return (true, 0);
    }

    function getRequiredAppealBond(uint256, uint8, bytes calldata) external pure returns (uint256, address) {
        return (0, address(0));
    }

    function moduleName() external pure returns (string memory) { return "Mock"; }
    function moduleVersion() external pure returns (string memory) { return "1.0"; }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
}