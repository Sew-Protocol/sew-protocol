// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol";
import "../../../contracts/decentralized-resolution-module/ResolverIncentiveModule.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EscalationFeeEnforcementTest is Test {
    DecentralizedResolutionModule public resolutionModule;
    ResolverIncentiveModule public incentiveModule;
    
    address public owner;
    address public timelock;
    address public escrowContract;
    address public resolver1;
    address public resolver2;
    address public seniorResolver;
    address public participant;
    
    uint256 public constant ESCALATION_FEE = 1 ether;
    uint256 public workflowId = 1;
    
    event EscalationFeePaid(uint256 indexed workflowId, uint256 fee);
    event DisputeEscalated(uint256 indexed workflowId, uint8 fromLevel, uint8 toLevel, address indexed newResolver);
    
    function setUp() public {
        owner = address(this);
        timelock = makeAddr("timelock");
        escrowContract = makeAddr("escrow");
        resolver1 = makeAddr("resolver1");
        resolver2 = makeAddr("resolver2");
        seniorResolver = makeAddr("seniorResolver");
        participant = makeAddr("participant");
        
        // Deploy Resolution Module
        DecentralizedResolutionModule implementation = new DecentralizedResolutionModule();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        resolutionModule = DecentralizedResolutionModule(address(proxy));
        resolutionModule.initialize(owner);
        
        // Grant roles
        resolutionModule.grantRole(resolutionModule.ROLE_TIMELOCK(), timelock);
        resolutionModule.registerEscrowContract(escrowContract);
        
        // Set up resolvers - must appoint senior resolver first
        vm.prank(timelock);
        resolutionModule.appointSeniorResolver(seniorResolver, "Senior Resolver", "Senior resolver");
        
        // Now senior resolver can appoint other resolvers
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver1, "Resolver 1", "First resolver");
        vm.prank(seniorResolver);
        resolutionModule.appointResolver(resolver2, "Resolver 2", "Second resolver");
        
        // Set resolvers as active and accepting new disputes
        resolutionModule.setResolverActive(resolver1, true);
        resolutionModule.setResolverActive(resolver2, true);
        resolutionModule.setResolverCapacity(resolver1, 10, true);
        resolutionModule.setResolverCapacity(resolver2, 10, true);
        
        // Configure escalation with fee
        vm.startPrank(timelock);
        resolutionModule.queueEscalationConfig(1, DecentralizedResolverStructs.EscalationConfig({
            resolver: address(0),
            fee: ESCALATION_FEE,
            enabled: true
        }));
        
        // Fast-forward time to activate (SLOW_DELAY = 7 days = 604800 seconds)
        (, uint64 eta, bool exists) = resolutionModule.getPendingEscalationConfig(1);
        require(exists, "Pending config should exist");
        vm.warp(eta + 1);
        resolutionModule.activateEscalationConfig(1);
        vm.stopPrank();
        
        // Initialize a dispute
        bytes32 category = keccak256("test-category");
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, category);
    }
    
    function test_EscalationFailsWithoutFee() public {
        // Try to escalate without marking fee as paid
        vm.expectRevert("Escalation fee not paid");
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");
    }
    
    function test_EscalationSucceedsWithFee() public {
        // Mark fee as paid
        vm.prank(escrowContract);
        vm.expectEmit(true, false, false, true);
        emit EscalationFeePaid(workflowId, ESCALATION_FEE);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE);
        
        // Now escalation should succeed
        vm.prank(escrowContract);
        vm.expectEmit(true, false, false, true);
        emit DisputeEscalated(workflowId, 0, 1, seniorResolver);
        (bool success, address newResolver, uint8 newLevel) = resolutionModule.executeEscalation(workflowId, "");
        
        assertTrue(success);
        assertEq(newLevel, 1);
        assertTrue(newResolver != address(0));
    }
    
    function test_EscalationFeeFlagClearedAfterUse() public {
        // Mark fee as paid
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE);
        
        // Escalate successfully
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");
        
        // Flag should be cleared - cannot escalate again without paying fee again
        assertFalse(resolutionModule.escalationFeePaid(workflowId));
        
        // Try to escalate again without paying fee - should fail
        // But first we need to configure level 2, otherwise it will fail for different reason
        address externalResolver = makeAddr("external");
        vm.prank(timelock);
        resolutionModule.setExternalResolver(externalResolver);
        
        vm.startPrank(timelock);
        resolutionModule.queueEscalationConfig(2, DecentralizedResolverStructs.EscalationConfig({
            resolver: externalResolver,
            fee: ESCALATION_FEE,
            enabled: true
        }));
        (, uint64 eta4, bool exists4) = resolutionModule.getPendingEscalationConfig(2);
        require(exists4, "Pending config should exist");
        vm.warp(eta4 + 1);
        resolutionModule.activateEscalationConfig(2);
        vm.stopPrank();
        
        // Now try to escalate to level 2 without paying fee - should fail
        vm.expectRevert("Escalation fee not paid");
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");
    }
    
    function test_EscalationWithZeroFeeDoesNotRequirePayment() public {
        // Configure escalation with zero fee
        vm.prank(timelock);
        resolutionModule.queueEscalationConfig(1, DecentralizedResolverStructs.EscalationConfig({
            resolver: address(0),
            fee: 0,
            enabled: true
        }));
        
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        resolutionModule.activateEscalationConfig(1);
        
        // Escalation should work without marking fee as paid
        vm.prank(escrowContract);
        (bool success, , ) = resolutionModule.executeEscalation(workflowId, "");
        assertTrue(success);
    }
    
    function test_OnlyEscrowContractCanMarkFeePaid() public {
        // Non-escrow contract cannot mark fee as paid
        vm.expectRevert("Not registered escrow contract");
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE);
        
        // Escrow contract can mark fee as paid
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE);
        assertTrue(resolutionModule.escalationFeePaid(workflowId));
    }
    
    function test_MultipleEscalationsRequireMultipleFees() public {
        // First escalation
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE);
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");
        
        // Second escalation (level 1 -> 2) also requires fee
        // Set up external resolver for level 2
        address externalResolver = makeAddr("external");
        vm.prank(timelock);
        resolutionModule.setExternalResolver(externalResolver);
        
        // Configure level 2 with fee
        vm.startPrank(timelock);
        resolutionModule.queueEscalationConfig(2, DecentralizedResolverStructs.EscalationConfig({
            resolver: externalResolver,
            fee: ESCALATION_FEE,
            enabled: true
        }));
        
        (, uint64 eta3, bool exists3) = resolutionModule.getPendingEscalationConfig(2);
        require(exists3, "Pending config should exist");
        vm.warp(eta3 + 1);
        resolutionModule.activateEscalationConfig(2);
        vm.stopPrank();
        
        // Try to escalate to level 2 without paying fee - should fail
        vm.expectRevert("Escalation fee not paid");
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");
        
        // Pay fee and escalate
        vm.prank(escrowContract);
        resolutionModule.markEscalationFeePaid(workflowId, ESCALATION_FEE);
        vm.prank(escrowContract);
        (bool success, address newResolver, uint8 newLevel) = resolutionModule.executeEscalation(workflowId, "");
        
        assertTrue(success);
        assertEq(newLevel, 2);
        assertEq(newResolver, externalResolver);
    }
}
