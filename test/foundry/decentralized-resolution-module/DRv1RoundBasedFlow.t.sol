// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol";
import "../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol";
import "../../../contracts/decentralized-resolution-module/ResolutionAnalytics.sol";

/**
 * @title DRv1RoundBasedFlowTest
 * @notice Tests for DR v1 round-based dispute flow, EMA scoring, and timeout handling
 */
contract DRv1RoundBasedFlowTest is Test, DecentralizedResolverStructs {
    DecentralizedResolutionModule public resolutionModule;
    
    address public owner = address(this);
    address public resolver1 = address(0x1);
    address public resolver2 = address(0x2);
    address public seniorResolver1 = address(0x11);
    address public seniorResolver2 = address(0x12);
    address public escrowContract = address(0xE5C);
    address public user = address(0xA11CE);
    
    uint256 public workflowId = 12345;
    
    function setUp() public {
        // Deploy DecentralizedResolutionModule
        DecentralizedResolutionModule implementation = new DecentralizedResolutionModule();
        
        // Create proxy with initialization
        bytes memory initData = abi.encodeWithSelector(
            DecentralizedResolutionModule.initialize.selector,
            owner
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        resolutionModule = DecentralizedResolutionModule(address(proxy));
        
        // Register escrow contract
        resolutionModule.registerEscrowContract(escrowContract);
        
        // Appoint resolvers
        resolutionModule.appointSeniorResolver(seniorResolver1, "Senior 1", "Senior Resolver 1");
        vm.prank(seniorResolver1);
        resolutionModule.appointResolver(resolver1, "Resolver 1", "Standard Resolver 1");
        vm.prank(seniorResolver1);
        resolutionModule.appointResolver(resolver2, "Resolver 2", "Standard Resolver 2");
        
        resolutionModule.appointSeniorResolver(seniorResolver2, "Senior 2", "Senior Resolver 2");
        
        // Set resolver capacities to accept disputes
        resolutionModule.setResolverCapacity(resolver1, 0, true); // 0 = unlimited
        resolutionModule.setResolverCapacity(resolver2, 0, true);
    }
    
    // ============ Round-Based Dispute Flow Tests ============
    
    function test_InitializeDispute_RoundBasedMetadata() public {
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));
        
        DisputeMetadata memory dm = resolutionModule.getDisputeMetadata(workflowId);
        
        // Check round-based initialization
        assertEq(dm.currentRound, 0, "Should start at round 0");
        assertEq(uint8(dm.status), uint8(DisputeStatus.Open), "Should be Open");
        assertEq(dm.resolverAtRound[0], resolver1, "Resolver at round 0");
        assertEq(dm.resolverAtRound[1], address(0), "No resolver at round 1 yet");
        assertEq(dm.resolverAtRound[2], address(0), "No resolver at round 2 yet");
        assertTrue(dm.assignedAt > 0, "Assignment timestamp set");
        assertGt(dm.resolveBy, dm.assignedAt, "Resolve deadline set");
    }
    
    function test_RecordResolution_UpdatesRoundData() public {
        // Initialize dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));
        
        // Record resolution
        vm.warp(block.timestamp + 1 days);
        vm.prank(escrowContract);
        resolutionModule.recordResolution(workflowId, resolver1, ResolutionOutcome.RELEASE, 1 days);
        
        DisputeMetadata memory dm = resolutionModule.getDisputeMetadata(workflowId);
        
        // Check round data was updated
        assertEq(uint8(dm.status), uint8(DisputeStatus.Decided), "Should be Decided");
        assertEq(uint8(dm.decisionAtRound[0]), uint8(ResolutionOutcome.RELEASE), "Decision recorded");
        assertEq(dm.decidedAtRound[0], block.timestamp, "Decision timestamp recorded");
        // Appeal window for round 0 is appealWindows[0] which defaults to 2 days
        assertGt(dm.appealDeadline[0], block.timestamp, "Appeal deadline set");
    }
    
    function test_ExecuteEscalation_UpdatesRoundMetadata() public {
        // Initialize dispute at round 0
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));
        
        // Record decision
        vm.warp(block.timestamp + 1 days);
        vm.prank(escrowContract);
        resolutionModule.recordResolution(workflowId, resolver1, ResolutionOutcome.RELEASE, 1 days);
        
        // Escalate to round 1
        vm.prank(escrowContract);
        (bool success, address newResolver, uint8 newRound) = resolutionModule.executeEscalation(workflowId, "");
        
        assertTrue(success, "Escalation should succeed");
        assertEq(newRound, 1, "Should escalate to round 1");
        assertEq(newResolver, seniorResolver1, "Senior resolver assigned");
        
        DisputeMetadata memory dm = resolutionModule.getDisputeMetadata(workflowId);
        assertEq(dm.currentRound, 1, "Current round should be 1");
        assertEq(uint8(dm.status), uint8(DisputeStatus.Escalated), "Should be Escalated");
        assertEq(dm.resolverAtRound[1], seniorResolver1, "Senior resolver at round 1");
        assertEq(dm.resolverAtRound[0], resolver1, "Original resolver still at round 0");
    }
    
    // ============ EMA Scoring Tests ============
    
    function test_EMAScore_InitializedForNewResolver() public {
        ResolverStats memory stats = resolutionModule.getDisputeResolverStats(resolver1);
        
        // Check EMA initialization (done in appointResolver via ResolutionAnalytics.initializeResolver)
        assertEq(stats.emaScore, ResolutionAnalytics.EMA_PRECISION, "New resolver starts with perfect EMA score");
        assertEq(stats.assignmentWeight, 10000, "New resolver has full assignment weight");
    }
    
    function test_EMAScore_UpdateOnSuccessfulResolution() public {
        // Initialize and resolve dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));
        
        uint256 initialEMA = resolutionModule.getDisputeResolverStats(resolver1).emaScore;
        
        vm.warp(block.timestamp + 1 days);
        vm.prank(escrowContract);
        resolutionModule.recordResolution(workflowId, resolver1, ResolutionOutcome.RELEASE, 1 days);
        
        ResolverStats memory stats = resolutionModule.getDisputeResolverStats(resolver1);
        
        // EMA should remain high for successful resolution (OUTCOME_UPHELD = 1e6)
        assertEq(stats.emaScore, initialEMA, "EMA stays at max for successful resolution");
        assertEq(stats.casesDecided, 1, "Cases decided incremented");
    }
    
    function test_EMAScore_UpdateOnReversal() public {
        // Initialize dispute and resolve at round 0
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));
        
        vm.warp(block.timestamp + 1 days);
        vm.prank(escrowContract);
        resolutionModule.recordResolution(workflowId, resolver1, ResolutionOutcome.RELEASE, 1 days);
        
        uint256 emaBeforeReversal = resolutionModule.getDisputeResolverStats(resolver1).emaScore;
        
        // Escalate to round 1
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");
        
        // Senior resolver makes different decision
        vm.warp(block.timestamp + 2 days);
        vm.prank(escrowContract);
        resolutionModule.recordResolution(workflowId, seniorResolver1, ResolutionOutcome.CANCEL, 2 days);
        
        // Record reversal explicitly
        vm.prank(escrowContract);
        resolutionModule.recordReversal(workflowId, 0);
        
        ResolverStats memory stats = resolutionModule.getDisputeResolverStats(resolver1);
        
        // EMA should decrease after reversal
        // With alpha=1000 (10%), score_new = 1e6 * 0.9 + 500000 * 0.1 = 950000
        assertEq(stats.emaScore, 950000, "EMA score should decrease to 950000 after reversal");
        assertEq(stats.reversals, 1, "Reversal count incremented");
    }
    
    // ============ Timeout Handling Tests ============
    
    function test_ForceProgress_TimeoutAndReassignment() public {
        // Initialize dispute
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));
        
        DisputeMetadata memory dmBefore = resolutionModule.getDisputeMetadata(workflowId);
        uint256 resolveBy = dmBefore.resolveBy;
        
        uint256 emaBeforeTimeout = resolutionModule.getDisputeResolverStats(resolver1).emaScore;
        
        // Warp past deadline
        vm.warp(resolveBy + 1);
        
        // Force progress (anyone can call)
        vm.prank(user);
        resolutionModule.forceProgress(workflowId);
        
        DisputeMetadata memory dmAfter = resolutionModule.getDisputeMetadata(workflowId);
        ResolverStats memory stats = resolutionModule.getDisputeResolverStats(resolver1);
        
        // Check timeout was recorded
        assertEq(stats.timeoutsResolve, 1, "Timeout count should increase");
        // EMA should decrease: score_new = 1e6 * 0.9 + 0 * 0.1 = 900000
        assertEq(stats.emaScore, 900000, "EMA score should decrease to 900000 after timeout");
        
        // Check reassignment (resolver2 should be assigned if available)
        assertEq(dmAfter.currentRound, 0, "Should stay at round 0");
        assertTrue(dmAfter.resolverAtRound[0] != address(0), "New resolver assigned");
    }
    
    function test_ForceProgress_RevertWhenNoTimeout() public {
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));
        
        // Try to force progress before timeout
        vm.expectRevert(bytes("No timeout"));
        vm.prank(user);
        resolutionModule.forceProgress(workflowId);
    }
    
    function test_ForceProgress_RevertWhenNotOpen() public {
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));
        
        // Record resolution (status becomes Decided)
        vm.warp(block.timestamp + 1 days);
        vm.prank(escrowContract);
        resolutionModule.recordResolution(workflowId, resolver1, ResolutionOutcome.RELEASE, 1 days);
        
        // Warp past original deadline
        DisputeMetadata memory dm = resolutionModule.getDisputeMetadata(workflowId);
        vm.warp(dm.resolveBy + 1);
        
        // Try to force progress when not Open
        vm.expectRevert("Not open");
        resolutionModule.forceProgress(workflowId);
    }
    
    // ============ Phase Gate Metrics Tests ============
    
    function test_PhaseGateMetrics_AfterReversals() public {
        // Create and resolve multiple disputes
        for (uint256 i = 0; i < 5; i++) {
            uint256 wfId = workflowId + i;
            vm.prank(escrowContract);
            resolutionModule.initializeDispute(wfId, resolver1, bytes32(0));
            
            vm.warp(block.timestamp + 1 days);
            vm.prank(escrowContract);
            resolutionModule.recordResolution(wfId, resolver1, ResolutionOutcome.RELEASE, 1 days);
            
            // Escalate and reverse for first 3 out of 5 (60% reversal rate)
            if (i < 3) {
                vm.prank(escrowContract);
                resolutionModule.executeEscalation(wfId, "");
                
                vm.warp(block.timestamp + 2 days);
                vm.prank(escrowContract);
                resolutionModule.recordResolution(wfId, seniorResolver1, ResolutionOutcome.CANCEL, 2 days);
                
                vm.prank(escrowContract);
                resolutionModule.recordReversal(wfId, 0);
            }
        }
        
        (uint256 escalationRate, uint256 avgResponseTime, uint256 activeResolvers) = 
            resolutionModule.getV1PhaseGateMetrics();
        
        // Escalation rate = 3 reversals / 8 total cases (5 resolver1 + 3 seniorResolver1) = 37.5%
        assertEq(escalationRate, 3750, "Escalation rate should be 37.5%");
        assertGt(avgResponseTime, 0, "Average response time should be > 0");
        assertGe(activeResolvers, 2, "At least 2 active resolvers");
    }
    
    // ============ EMA Parameter Governance Tests ============
    
    function test_SetEMAParameters_Success() public {
        resolutionModule.setEMAParameters(2000, 600000, 4000);
        
        // Parameters are internal, check via resolver selection behavior
        // This is indirect verification - parameters affect workload weight calculation
    }
    
    function test_SetEMAParameters_RevertWhenInvalidAlpha() public {
        vm.expectRevert("Invalid alpha");
        resolutionModule.setEMAParameters(10001, 500000, 3000);
    }
    
    function test_SetEMAParameters_RevertWhenInvalidThreshold() public {
        vm.expectRevert("Invalid threshold");
        resolutionModule.setEMAParameters(1000, 1000001, 3000);
    }
    
    function test_SetRoundTimeouts_Success() public {
        uint256[3] memory resolveDeadlines = [uint256(2 days), uint256(4 days), uint256(6 days)];
        uint256[3] memory appealWindows = [uint256(1 days), uint256(2 days), uint256(0)];
        
        resolutionModule.setRoundTimeouts(resolveDeadlines, appealWindows);
        
        // Verify by initializing a new dispute and checking deadline
        uint256 newWorkflowId = workflowId + 100;
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(newWorkflowId, resolver1, bytes32(0));
        
        DisputeMetadata memory dm = resolutionModule.getDisputeMetadata(newWorkflowId);
        assertEq(dm.resolveBy, block.timestamp + 2 days, "New resolve deadline applied");
    }
    
    // ============ Integration Tests ============
    
    function test_FullDisputeLifecycle_ThreeRounds() public {
        // Round 0: Standard resolver
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId, resolver1, bytes32(0));
        
        vm.warp(block.timestamp + 1 days);
        vm.prank(escrowContract);
        resolutionModule.recordResolution(workflowId, resolver1, ResolutionOutcome.RELEASE, 1 days);
        
        // Round 1: Senior resolver (escalate and reverse)
        vm.prank(escrowContract);
        resolutionModule.executeEscalation(workflowId, "");
        
        vm.warp(block.timestamp + 2 days);
        vm.prank(escrowContract);
        resolutionModule.recordResolution(workflowId, seniorResolver1, ResolutionOutcome.CANCEL, 2 days);
        
        vm.prank(escrowContract);
        resolutionModule.recordReversal(workflowId, 0);
        
        // Round 2: External (Kleros) - set external resolver first
        address klerosProxy = address(0xC1E705);
        resolutionModule.setExternalResolver(klerosProxy);
        
        vm.prank(escrowContract);
        (bool success, address externalResolver, uint8 finalRound) = resolutionModule.executeEscalation(workflowId, "");
        
        assertTrue(success, "Final escalation should succeed");
        assertEq(finalRound, 2, "Should be at round 2");
        assertEq(externalResolver, klerosProxy, "External resolver assigned");
        
        DisputeMetadata memory dm = resolutionModule.getDisputeMetadata(workflowId);
        assertEq(dm.currentRound, 2, "Final round is 2");
        assertEq(dm.resolverAtRound[0], resolver1, "Round 0 resolver preserved");
        assertEq(dm.resolverAtRound[1], seniorResolver1, "Round 1 resolver preserved");
        assertEq(dm.resolverAtRound[2], klerosProxy, "Round 2 resolver assigned");
    }
}

// Mock ERC1967Proxy for testing
contract ERC1967Proxy {
    address private immutable _implementation;
    
    constructor(address implementation, bytes memory data) {
        _implementation = implementation;
        if (data.length > 0) {
            (bool success,) = implementation.delegatecall(data);
            require(success, "Init failed");
        }
    }
    
    fallback() external payable {
        address impl = _implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
    
    receive() external payable {}
}
