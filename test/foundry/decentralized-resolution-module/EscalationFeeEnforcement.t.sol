// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol";
import "../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EscalationFeeEnforcementTest is Test {
    DecentralizedResolutionModule public resolutionModule;
    address public owner;
    address public timelock;
    address public escrowContract;
    address public resolver1;
    address public resolver2;
    address public seniorResolver;
    address public externalResolver;

    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    uint256 public constant ESCALATION_FEE_LEVEL_1 = 100e18; // 100 tokens
    uint256 public constant ESCALATION_FEE_LEVEL_2 = 200e18; // 200 tokens

    event EscalationFeePaid(uint256 indexed workflowId, uint256 fee);
    event DisputeEscalatedToRound(uint256 indexed workflowId, uint8 fromRound, uint8 toRound, address indexed newResolver);

    function setUp() public {
        owner = address(this);
        timelock = makeAddr("timelock");
        escrowContract = makeAddr("escrow");
        resolver1 = makeAddr("resolver1");
        resolver2 = makeAddr("resolver2");
        seniorResolver = makeAddr("seniorResolver");
        externalResolver = makeAddr("externalResolver");

        // Deploy Implementation
        DecentralizedResolutionModule implementation = new DecentralizedResolutionModule();

        // Deploy Proxy and Initialize
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSelector(
                DecentralizedResolutionModule.initialize.selector,
                owner
            )
        );

        resolutionModule = DecentralizedResolutionModule(payable(address(proxy)));

        // Setup roles
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);
        resolutionModule.registerEscrowContract(escrowContract);

        // Appoint senior resolver first (needs to be done by timelock)
        resolutionModule.appointSeniorResolver(seniorResolver, "Senior Resolver", "Senior resolver");
        
        // Appoint resolvers (now seniorResolver can appoint)
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver1, "Resolver 1", "First resolver");
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver2, "Resolver 2", "Second resolver");
        
        // Set resolvers as active and accepting new disputes
        resolutionModule.setResolverActive(resolver1, true);
        resolutionModule.setResolverActive(resolver2, true);
        resolutionModule.setResolverCapacity(resolver1, 10, true); // max 10 disputes, accepting
        resolutionModule.setResolverCapacity(resolver2, 10, true);
        
        // Set external resolver
        resolutionModule.setExternalResolver(externalResolver);

        // Configure escalation fees
        // Level 1 is already enabled with fee 0 in initialization
        // We need to queue and activate a new config with fee for level 1
        vm.startPrank(timelock);
        
        // Level 1: Senior resolver escalation (update from fee 0 to ESCALATION_FEE_LEVEL_1)
        DecentralizedResolverStructs.EscalationConfig memory config1 = DecentralizedResolverStructs.EscalationConfig({
            resolver: address(0), // Dynamic selection
            fee: ESCALATION_FEE_LEVEL_1,
            enabled: true
        });
        resolutionModule.queueEscalationConfig(1, config1);
        
        // Verify pending config exists
        (DecentralizedResolverStructs.EscalationConfig memory pendingConfig, uint64 eta, bool exists) = 
            resolutionModule.getPendingEscalationConfig(1);
        require(exists, "Pending config should exist");
        
        // SLOW_DELAY is 7 days = 604800 seconds
        vm.warp(eta + 1);
        resolutionModule.activateEscalationConfig(1);

        // Level 2: External resolver escalation (currently disabled in init, need to enable)
        DecentralizedResolverStructs.EscalationConfig memory config2 = DecentralizedResolverStructs.EscalationConfig({
            resolver: externalResolver,
            fee: ESCALATION_FEE_LEVEL_2,
            enabled: true
        });
        resolutionModule.queueEscalationConfig(2, config2);
        
        // Verify pending config exists and warp to its ETA
        (, uint64 eta2, bool exists2) = resolutionModule.getPendingEscalationConfig(2);
        require(exists2, "Pending config should exist");
        vm.warp(eta2 + 1);
        resolutionModule.activateEscalationConfig(2);
        vm.stopPrank();
    }

    function test_EscalationFailsWithoutFeePayment() public {
        uint256 workflowId = 1;
        bytes32 category = keccak256("TEST_CATEGORY");

        // Initialize dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, category);

        // Try to escalate without marking fee as paid
        // Should revert with "Escalation fee not paid"
        vm.expectRevert("Escalation fee not paid");
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");
    }

    function test_EscalationSucceedsWithFeePayment() public {
        uint256 workflowId = 1;
        bytes32 category = keccak256("TEST_CATEGORY");

        // Initialize dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, category);

        // Mark fee as paid
        vm.expectEmit(true, false, false, true);
        emit EscalationFeePaid(workflowId, ESCALATION_FEE_LEVEL_1);
        
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE_LEVEL_1);

        // Now escalation should succeed
        vm.expectEmit(true, false, false, true);
        emit DisputeEscalatedToRound(workflowId, 0, 1, seniorResolver);
        
        vm.prank(escrowContract);
        (bool success, address newResolver, uint8 newLevel) = resolutionModule.executeEscalation(workflowId, "");
        
        assertTrue(success, "Escalation should succeed with fee payment");
        assertTrue(newResolver != address(0), "New resolver should be assigned");
        assertEq(newLevel, 1, "Should escalate to level 1");
    }

    function test_EscalationFeeFlagClearedAfterUse() public {
        uint256 workflowId = 1;
        bytes32 category = keccak256("TEST_CATEGORY");

        // Initialize dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, category);

        // Mark fee as paid
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE_LEVEL_1);

        // Verify flag is set
        assertTrue(resolutionModule.escalationFeePaid(workflowId), "Fee should be marked as paid");

        // Execute escalation
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");

        // Verify flag is cleared
        assertFalse(resolutionModule.escalationFeePaid(workflowId), "Fee flag should be cleared after escalation");
    }

    function test_CannotReuseEscalationFee() public {
        uint256 workflowId = 1;
        bytes32 category = keccak256("TEST_CATEGORY");

        // Initialize dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, category);

        // Mark fee as paid and escalate
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE_LEVEL_1);
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");

        // Try to escalate again without marking new fee
        // Should revert because flag was cleared
        vm.expectRevert("Escalation fee not paid");
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");
    }

    function test_EscalationToLevel2RequiresFee() public {
        uint256 workflowId = 1;
        bytes32 category = keccak256("TEST_CATEGORY");

        // Initialize dispute and escalate to level 1
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, category);
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE_LEVEL_1);
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");

        // Try to escalate to level 2 without fee
        // Should revert with "Escalation fee not paid"
        vm.expectRevert("Escalation fee not paid");
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");

        // Mark fee for level 2 and escalate
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE_LEVEL_2);
        
        vm.expectEmit(true, false, false, true);
        emit DisputeEscalatedToRound(workflowId, 1, 2, externalResolver);
        
        vm.prank(escrowContract);
        (bool success3, address newResolver5, uint8 newLevel) = resolutionModule.executeEscalation(workflowId, "");
        
        assertTrue(success3, "Escalation to level 2 should succeed with fee");
        assertEq(newLevel, 2, "Should escalate to level 2");
    }

    function test_ZeroFeeEscalationDoesNotRequirePayment() public {
        uint256 workflowId = 1;
        bytes32 category = keccak256("TEST_CATEGORY");

        // Set escalation fee to 0 (revert level 1 back to zero fee)
        DecentralizedResolverStructs.EscalationConfig memory config = DecentralizedResolverStructs.EscalationConfig({
            resolver: address(0),
            fee: 0,
            enabled: true
        });
        vm.startPrank(timelock);
        resolutionModule.queueEscalationConfig(1, config);
        (, uint64 eta3, bool exists3) = resolutionModule.getPendingEscalationConfig(1);
        require(exists3, "Pending config should exist");
        vm.warp(eta3 + 1);
        resolutionModule.activateEscalationConfig(1);
        vm.stopPrank();

        // Initialize dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, category);

        // Escalation should succeed without marking fee (because fee is 0)
        vm.prank(escrowContract);
        (bool success, , uint8 newLevel) = resolutionModule.executeEscalation(workflowId, "");
        
        assertTrue(success, "Escalation with zero fee should succeed without payment");
        assertEq(newLevel, 1, "Should escalate to level 1");
    }

    function test_OnlyEscrowContractCanMarkFeePaid() public {
        uint256 workflowId = 1;
        
        // Try to mark fee as paid from non-escrow address
        vm.expectRevert("Not registered escrow contract");
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE_LEVEL_1);
    }

    function test_MultipleEscalationsRequireMultipleFees() public {
        uint256 workflowId = 1;
        bytes32 category = keccak256("TEST_CATEGORY");

        // Initialize dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, category);

        // First escalation
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE_LEVEL_1);
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");

        // Second escalation requires new fee
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE_LEVEL_2);
        vm.prank(escrowContract);
        (bool success, address newResolver2, uint8 newLevel) = resolutionModule.executeEscalation(workflowId, "");
        
        assertTrue(success, "Second escalation should succeed with new fee");
        assertEq(newLevel, 2, "Should escalate to level 2");
    }
}
