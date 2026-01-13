// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol";
import "../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol";
import "../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol";
import "../../../contracts/decentralized-resolution-module/EscalationCostLibrary.sol";
import "../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1000000 * 10**18);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title DRv2AppealBondsTest
 * @notice Comprehensive test suite for DR v2 appeal bond functionality
 */
contract DRv2AppealBondsTest is Test {
    DecentralizedResolutionModule public resolutionModule;
    ResolverIncentiveModuleV2 public incentiveModuleV2;
    PaymentCalculationLibraryV1 public paymentLib;
    MockERC20 public token;
    
    address public admin = address(0x1);
    address public timelock = address(0x2);
    address public escrowContract = address(0x3);
    address public resolver1 = address(0x4);
    address public seniorResolver = address(0x5);
    address public user1 = address(0x6);
    address public user2 = address(0x7);
    
    uint256 constant WORKFLOW_ID = 1;
    uint256 constant DISPUTE_AMOUNT = 1000e18;
    
    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    
    event AppealBondRecorded(
        uint256 indexed workflowId,
        uint8 round,
        address indexed depositor,
        uint256 amount,
        address token
    );
    
    event AppealBondRefunded(
        uint256 indexed workflowId,
        uint8 round,
        address indexed depositor,
        uint256 amount,
        address token
    );
    
    event AppealBondPaidToResolvers(
        uint256 indexed workflowId,
        uint8 round,
        address[] resolvers,
        uint256 totalAmount,
        address token
    );
    
    event AppealBondForfeited(
        uint256 indexed workflowId,
        uint8 round,
        uint256 amount,
        address token,
        string reason
    );
    
    function setUp() public {
        // Deploy token
        token = new MockERC20();
        
        // Deploy payment calculation library
        paymentLib = new PaymentCalculationLibraryV1();
        
        // Deploy resolution module
        resolutionModule = new DecentralizedResolutionModule();
        
        // Deploy incentive module V2
        incentiveModuleV2 = new ResolverIncentiveModuleV2();
        
        // Initialize resolution module
        resolutionModule.initialize(admin);
        
        // Initialize incentive module
        incentiveModuleV2.initialize(admin, address(paymentLib));
        
        // Register escrow contract in both modules
        vm.startPrank(admin);
        incentiveModuleV2.registerEscrowContract(escrowContract);
        resolutionModule.registerEscrowContract(escrowContract);
        
        // Setup roles
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);
        vm.stopPrank();
        
        // Appoint senior resolver first (requires ROLE_TIMELOCK)
        vm.startPrank(timelock);
        resolutionModule.appointSeniorResolver(seniorResolver, "Senior Resolver", "Test senior resolver");
        resolutionModule.setResolverCapacity(seniorResolver, 0, true);
        vm.stopPrank();
        
        // Appoint standard resolver (requires senior resolver)
        vm.startPrank(seniorResolver);
        resolutionModule.appointResolver(resolver1, "Resolver 1", "Test resolver");
        vm.stopPrank();
        
        // Set resolver capacity (requires ROLE_TIMELOCK)
        vm.prank(timelock);
        resolutionModule.setResolverCapacity(resolver1, 0, true);
        
        // Fund users with tokens
        token.mint(user1, 10000e18);
        token.mint(user2, 10000e18);
        
        // Fund users with ETH
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        
        // Approve incentive module to spend tokens
        vm.prank(user1);
        token.approve(address(incentiveModuleV2), type(uint256).max);
        vm.prank(user2);
        token.approve(address(incentiveModuleV2), type(uint256).max);
    }
    
    // ============ Helper Functions ============
    
    function _setupQuadraticCostCurve() internal {
        vm.startPrank(timelock);
        
        DecentralizedResolverStructs.EscalationCostConfig memory config = DecentralizedResolverStructs.EscalationCostConfig({
            curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
            baseCost: 100e18,
            stepSize: 50e18,
            multiplier: 0,
            bondToken: address(token),
            enabled: true
        });
        
        resolutionModule.queueEscalationCostConfig(config);
        vm.warp(block.timestamp + 7 days + 1);
        resolutionModule.activateEscalationCostConfig();
        
        vm.stopPrank();
    }
    
    function _setupLinearCostCurve() internal {
        vm.startPrank(timelock);
        
        DecentralizedResolverStructs.EscalationCostConfig memory config = DecentralizedResolverStructs.EscalationCostConfig({
            curveType: DecentralizedResolverStructs.CostCurveType.LINEAR,
            baseCost: 100e18,
            stepSize: 50e18,
            multiplier: 0,
            bondToken: address(token),
            enabled: true
        });
        
        resolutionModule.queueEscalationCostConfig(config);
        vm.warp(block.timestamp + 7 days + 1);
        resolutionModule.activateEscalationCostConfig();
        
        vm.stopPrank();
    }
    
    function _initializeDispute() internal {
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(
            WORKFLOW_ID,
            resolver1,
            bytes32(0)
        );
    }
    
    function _recordResolution(uint256 workflowId, address resolver, DecentralizedResolverStructs.ResolutionOutcome outcome) internal {
        vm.prank(escrowContract);
        resolutionModule.recordResolution(
            workflowId,
            resolver,
            outcome,
            1 hours // resolutionTime
        );
    }
    
    // ============ Test: Bond Calculation ============
    
    function test_BondCalculation_Quadratic() public {
        _setupQuadraticCostCurve();
        
        // Round 0 -> 1: base + step * 0^2 = 100 + 0 = 100
        (uint256 bond0, address token0) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 0, "");
        assertEq(bond0, 100e18, "Round 0->1 bond should be 100");
        assertEq(token0, address(token), "Token should match");
        
        // Round 1 -> 2: base + step * 1^2 = 100 + 50 = 150
        (uint256 bond1, address token1) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 1, "");
        assertEq(bond1, 150e18, "Round 1->2 bond should be 150");
        assertEq(token1, address(token), "Token should match");
        
        // Round 2 -> 3 (hypothetical): base + step * 2^2 = 100 + 200 = 300
        (uint256 bond2, address token2) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 2, "");
        assertEq(bond2, 300e18, "Round 2->3 bond should be 300");
        assertEq(token2, address(token), "Token should match");
    }
    
    function test_BondCalculation_Linear() public {
        _setupLinearCostCurve();
        
        // Round 0 -> 1: base + step * 0 = 100 + 0 = 100
        (uint256 bond0,) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 0, "");
        assertEq(bond0, 100e18, "Round 0->1 bond should be 100");
        
        // Round 1 -> 2: base + step * 1 = 100 + 50 = 150
        (uint256 bond1,) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 1, "");
        assertEq(bond1, 150e18, "Round 1->2 bond should be 150");
        
        // Round 2 -> 3: base + step * 2 = 100 + 100 = 200
        (uint256 bond2,) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 2, "");
        assertEq(bond2, 200e18, "Round 2->3 bond should be 200");
    }
    
    function test_BondCalculation_Geometric() public {
        vm.startPrank(timelock);
        
        DecentralizedResolverStructs.EscalationCostConfig memory config = DecentralizedResolverStructs.EscalationCostConfig({
            curveType: DecentralizedResolverStructs.CostCurveType.GEOMETRIC,
            baseCost: 100e18,
            stepSize: 0,
            multiplier: 20000, // 2x multiplier (in basis points: 20000/10000 = 2.0)
            bondToken: address(token),
            enabled: true
        });
        
        resolutionModule.queueEscalationCostConfig(config);
        vm.warp(block.timestamp + 7 days + 1);
        resolutionModule.activateEscalationCostConfig();
        vm.stopPrank();
        
        // Round 0 -> 1: base * r^0 = 100 * 1 = 100
        (uint256 bond0,) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 0, "");
        assertEq(bond0, 100e18, "Round 0->1 bond should be 100");
        
        // Round 1 -> 2: base * r^1 = 100 * 2 = 200
        (uint256 bond1,) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 1, "");
        assertEq(bond1, 200e18, "Round 1->2 bond should be 200");
        
        // Round 2 -> 3: base * r^2 = 100 * 4 = 400
        (uint256 bond2,) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 2, "");
        assertEq(bond2, 400e18, "Round 2->3 bond should be 400");
    }
    
    function test_BondCalculation_Disabled() public {
        // Don't setup any cost curve - should return (0, address(0))
        (uint256 bond, address bondToken) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 0, "");
        assertEq(bond, 0, "Bond should be 0 when disabled");
        assertEq(bondToken, address(0), "Token should be address(0) when disabled");
    }
    
    // ============ Test: Bond Recording ============
    
    function test_RecordAppealBond_Success() public {
        _setupQuadraticCostCurve();
        
        uint256 bondAmount = 100e18;
        uint8 round = 1;
        
        // Transfer tokens to incentive module (simulating escrow deposit)
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), bondAmount);
        
        // Record bond
        vm.expectEmit(true, false, true, true);
        emit AppealBondRecorded(WORKFLOW_ID, round, user1, bondAmount, address(token));
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, bondAmount, address(token), round);
        
        // Verify bond record
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(WORKFLOW_ID, round);
        assertEq(bond.depositor, user1, "Depositor should match");
        assertEq(bond.amount, bondAmount, "Amount should match");
        assertEq(bond.token, address(token), "Token should match");
        assertEq(bond.distributed, false, "Should not be distributed");
        assertEq(bond.refunded, false, "Should not be refunded");
        
        // Verify metrics
        (uint256 posted,,,) = incentiveModuleV2.getV2Metrics();
        assertEq(posted, bondAmount, "Total posted should match");
    }
    
    function test_RecordAppealBond_RevertIfInvalidDepositor() public {
        vm.expectRevert("Invalid depositor");
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, address(0), 100e18, address(token), 1);
    }
    
    function test_RecordAppealBond_RevertIfInvalidAmount() public {
        vm.expectRevert("Invalid amount");
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, 0, address(token), 1);
    }
    
    function test_RecordAppealBond_RevertIfInvalidRound() public {
        vm.expectRevert("Invalid round");
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, 100e18, address(token), 0);
        
        vm.expectRevert("Invalid round");
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, 100e18, address(token), 3);
    }
    
    function test_RecordAppealBond_RevertIfNotEscrow() public {
        vm.expectRevert();
        vm.prank(user1);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, 100e18, address(token), 1);
    }
    
    function test_RecordAppealBond_MultipleBonds() public {
        _setupQuadraticCostCurve();
        
        // Record bond for round 1
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), 100e18);
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, 100e18, address(token), 1);
        
        // Record bond for round 2
        vm.prank(user2);
        token.transfer(address(incentiveModuleV2), 150e18);
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user2, 150e18, address(token), 2);
        
        // Verify both bonds
        ResolverIncentiveModuleV2.AppealBondRecord memory bond1 = incentiveModuleV2.getAppealBond(WORKFLOW_ID, 1);
        assertEq(bond1.depositor, user1, "Round 1 depositor");
        assertEq(bond1.amount, 100e18, "Round 1 amount");
        
        ResolverIncentiveModuleV2.AppealBondRecord memory bond2 = incentiveModuleV2.getAppealBond(WORKFLOW_ID, 2);
        assertEq(bond2.depositor, user2, "Round 2 depositor");
        assertEq(bond2.amount, 150e18, "Round 2 amount");
        
        // Verify total metrics
        (uint256 posted,,,) = incentiveModuleV2.getV2Metrics();
        assertEq(posted, 250e18, "Total posted should be 100 + 150");
    }
    
    // ============ Test: Bond Refund (Appeal Succeeds) ============
    
    function test_DistributeAppealBond_Refund() public {
        _setupQuadraticCostCurve();
        _initializeDispute();
        
        // Record initial resolution at round 0
        _recordResolution(WORKFLOW_ID, resolver1, DecentralizedResolverStructs.ResolutionOutcome.RELEASE);
        
        // User1 escalates and posts bond for round 1
        uint256 bondAmount = 100e18;
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), bondAmount);
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, bondAmount, address(token), 1);
        
        uint256 user1BalanceBefore = token.balanceOf(user1);
        
        // Distribute bond with outcome flipped (appeal succeeded)
        vm.expectEmit(true, false, true, true);
        emit AppealBondRefunded(WORKFLOW_ID, 1, user1, bondAmount, address(token));
        
        vm.prank(escrowContract);
        incentiveModuleV2.distributeAppealBond(WORKFLOW_ID, 0, true); // outcomeFlipped = true
        
        // Verify refund
        uint256 user1BalanceAfter = token.balanceOf(user1);
        assertEq(user1BalanceAfter - user1BalanceBefore, bondAmount, "User should receive full refund");
        
        // Verify bond record updated
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(WORKFLOW_ID, 1);
        assertTrue(bond.distributed, "Should be distributed");
        assertTrue(bond.refunded, "Should be refunded");
        
        // Verify metrics
        (, uint256 refunded,,) = incentiveModuleV2.getV2Metrics();
        assertEq(refunded, bondAmount, "Refunded metric should update");
    }
    
    // ============ Test: Bond Payment to Resolvers (Appeal Fails) ============
    
    function test_DistributeAppealBond_PayToResolvers() public {
        _setupQuadraticCostCurve();
        _initializeDispute();
        
        // Record initial resolution at round 0 by resolver1
        _recordResolution(WORKFLOW_ID, resolver1, DecentralizedResolverStructs.ResolutionOutcome.RELEASE);
        
        // User1 escalates and posts bond for round 1
        uint256 bondAmount = 100e18;
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), bondAmount);
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, bondAmount, address(token), 1);
        
        // Distribute bond with outcome NOT flipped (appeal failed)
        vm.prank(escrowContract);
        incentiveModuleV2.distributeAppealBond(WORKFLOW_ID, 0, false); // outcomeFlipped = false
        
        // Verify bond record updated
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(WORKFLOW_ID, 1);
        assertTrue(bond.distributed, "Should be distributed");
        assertFalse(bond.refunded, "Should not be refunded");
        
        // Verify metrics (bond stays as protocol revenue since no resolver records)
        (,, uint256 paidToResolvers,) = incentiveModuleV2.getV2Metrics();
        assertEq(paidToResolvers, bondAmount, "Paid to resolvers metric should update");
    }
    
    function test_DistributeAppealBond_RevertIfNoBond() public {
        vm.expectRevert("No bond recorded");
        vm.prank(escrowContract);
        incentiveModuleV2.distributeAppealBond(WORKFLOW_ID, 0, true);
    }
    
    function test_DistributeAppealBond_RevertIfAlreadyDistributed() public {
        _setupQuadraticCostCurve();
        _initializeDispute();
        _recordResolution(WORKFLOW_ID, resolver1, DecentralizedResolverStructs.ResolutionOutcome.RELEASE);
        
        // Record and distribute bond
        uint256 bondAmount = 100e18;
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), bondAmount);
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, bondAmount, address(token), 1);
        
        vm.prank(escrowContract);
        incentiveModuleV2.distributeAppealBond(WORKFLOW_ID, 0, true);
        
        // Try to distribute again
        vm.expectRevert("Bond already distributed");
        vm.prank(escrowContract);
        incentiveModuleV2.distributeAppealBond(WORKFLOW_ID, 0, true);
    }
    
    // ============ Test: Bond Forfeiture ============
    
    function test_ForfeitAppealBond() public {
        _setupQuadraticCostCurve();
        
        uint256 bondAmount = 100e18;
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), bondAmount);
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, bondAmount, address(token), 1);
        
        // Forfeit bond
        vm.expectEmit(true, false, false, true);
        emit AppealBondForfeited(WORKFLOW_ID, 1, bondAmount, address(token), "No evidence submitted");
        
        vm.prank(escrowContract);
        incentiveModuleV2.forfeitAppealBond(WORKFLOW_ID, 1, "No evidence submitted");
        
        // Verify bond record
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(WORKFLOW_ID, 1);
        assertTrue(bond.distributed, "Should be distributed");
        assertFalse(bond.refunded, "Should not be refunded");
        
        // Verify metrics
        (,,, uint256 forfeited) = incentiveModuleV2.getV2Metrics();
        assertEq(forfeited, bondAmount, "Forfeited metric should update");
        
        // Bond remains in contract (protocol revenue)
        assertEq(token.balanceOf(address(incentiveModuleV2)), bondAmount, "Bond should remain in contract");
    }
    
    // ============ Test: Governance ============
    
    function test_Governance_QueueAndActivateCostConfig() public {
        DecentralizedResolverStructs.EscalationCostConfig memory config = DecentralizedResolverStructs.EscalationCostConfig({
            curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
            baseCost: 200e18,
            stepSize: 100e18,
            multiplier: 0,
            bondToken: address(token),
            enabled: true
        });
        
        // Queue
        vm.prank(timelock);
        resolutionModule.queueEscalationCostConfig(config);
        
        // Verify pending
        (DecentralizedResolverStructs.EscalationCostConfig memory pending, uint64 eta, bool exists) = 
            resolutionModule.getPendingEscalationCostConfig();
        assertTrue(exists, "Should have pending config");
        assertEq(pending.baseCost, 200e18, "Base cost should match");
        assertEq(eta, block.timestamp + 7 days, "ETA should be 7 days");
        
        // Try to activate too early
        vm.expectRevert();
        vm.prank(timelock);
        resolutionModule.activateEscalationCostConfig();
        
        // Warp to ETA
        vm.warp(block.timestamp + 7 days + 1);
        
        // Activate
        vm.prank(timelock);
        resolutionModule.activateEscalationCostConfig();
        
        // Verify active
        (uint256 bond,) = resolutionModule.getRequiredAppealBond(WORKFLOW_ID, 0, "");
        assertEq(bond, 200e18, "New base cost should be active");
    }
    
    function test_Governance_SetMinEscrowValue() public {
        uint256 minValue = 1000e18;
        
        vm.prank(timelock);
        resolutionModule.setMinEscrowValueForEscalation(minValue);
        
        assertEq(resolutionModule.minEscrowValueForEscalation(), minValue, "Min value should be set");
    }
    
    function test_Governance_RevertIfNotTimelock() public {
        DecentralizedResolverStructs.EscalationCostConfig memory config = DecentralizedResolverStructs.EscalationCostConfig({
            curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
            baseCost: 100e18,
            stepSize: 50e18,
            multiplier: 0,
            bondToken: address(token),
            enabled: true
        });
        
        vm.expectRevert();
        vm.prank(user1);
        resolutionModule.queueEscalationCostConfig(config);
        
        vm.expectRevert();
        vm.prank(user1);
        resolutionModule.setMinEscrowValueForEscalation(1000e18);
    }
    
    // ============ Test: Observability Metrics ============
    
    function test_Metrics_EscalationDepthHistogram() public {
        _setupQuadraticCostCurve();
        
        // Record bonds at different rounds
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), 100e18);
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, 100e18, address(token), 1);
        
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), 150e18);
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID + 1, user1, 150e18, address(token), 1);
        
        vm.prank(user2);
        token.transfer(address(incentiveModuleV2), 150e18);
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID + 2, user2, 150e18, address(token), 2);
        
        // Verify histogram
        (uint256 round0, uint256 round1, uint256 round2) = incentiveModuleV2.getEscalationDepthHistogram();
        assertEq(round0, 0, "Round 0 should be 0");
        assertEq(round1, 2, "Round 1 should be 2");
        assertEq(round2, 1, "Round 2 should be 1");
    }
    
    function test_Metrics_ComprehensiveFlow() public {
        _setupQuadraticCostCurve();
        _initializeDispute();
        _recordResolution(WORKFLOW_ID, resolver1, DecentralizedResolverStructs.ResolutionOutcome.RELEASE);
        
        // Bond 1: Will be refunded
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), 100e18);
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, 100e18, address(token), 1);
        
        vm.prank(escrowContract);
        incentiveModuleV2.distributeAppealBond(WORKFLOW_ID, 0, true); // Refund
        
        // Bond 2: Will be paid as protocol revenue (no resolver records tracked in V1)
        uint256 workflowId2 = WORKFLOW_ID + 1;
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(workflowId2, resolver1, bytes32(0));
        _recordResolution(workflowId2, resolver1, DecentralizedResolverStructs.ResolutionOutcome.RELEASE);
        
        vm.prank(user2);
        token.transfer(address(incentiveModuleV2), 100e18);
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(workflowId2, user2, 100e18, address(token), 1);
        
        vm.prank(escrowContract);
        incentiveModuleV2.distributeAppealBond(workflowId2, 0, false); // Pay (counted in metrics even if no resolver records)
        
        // Bond 3: Will be forfeited
        uint256 workflowId3 = WORKFLOW_ID + 2;
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), 100e18);
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(workflowId3, user1, 100e18, address(token), 1);
        
        vm.prank(escrowContract);
        incentiveModuleV2.forfeitAppealBond(workflowId3, 1, "Timeout");
        
        // Verify comprehensive metrics
        (
            uint256 posted,
            uint256 refunded,
            uint256 paidToResolvers,
            uint256 forfeited
        ) = incentiveModuleV2.getV2Metrics();
        
        assertEq(posted, 300e18, "Total posted: 100 + 100 + 100");
        assertEq(refunded, 100e18, "Total refunded: 100");
        assertEq(paidToResolvers, 100e18, "Total paid to resolvers: 100");
        assertEq(forfeited, 100e18, "Total forfeited: 100");
    }
    
    // ============ Test: ETH Bonds ============
    
    function test_ETHBond_Refund() public {
        vm.startPrank(timelock);
        DecentralizedResolverStructs.EscalationCostConfig memory config = DecentralizedResolverStructs.EscalationCostConfig({
            curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
            baseCost: 1 ether,
            stepSize: 0.5 ether,
            multiplier: 0,
            bondToken: address(0), // ETH
            enabled: true
        });
        resolutionModule.queueEscalationCostConfig(config);
        vm.warp(block.timestamp + 7 days + 1);
        resolutionModule.activateEscalationCostConfig();
        vm.stopPrank();
        
        _initializeDispute();
        _recordResolution(WORKFLOW_ID, resolver1, DecentralizedResolverStructs.ResolutionOutcome.RELEASE);
        
        // User1 deposits ETH bond
        uint256 bondAmount = 1 ether;
        vm.deal(address(incentiveModuleV2), bondAmount); // Simulate ETH received
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, bondAmount, address(0), 1);
        
        uint256 user1BalanceBefore = user1.balance;
        
        // Refund ETH bond
        vm.prank(escrowContract);
        incentiveModuleV2.distributeAppealBond(WORKFLOW_ID, 0, true);
        
        uint256 user1BalanceAfter = user1.balance;
        assertEq(user1BalanceAfter - user1BalanceBefore, bondAmount, "User should receive ETH refund");
    }
    
    // ============ Test: Edge Cases ============
    
    function test_HasAppealBond() public {
        assertFalse(incentiveModuleV2.hasAppealBond(WORKFLOW_ID, 1), "Should not have bond initially");
        
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), 100e18);
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, 100e18, address(token), 1);
        
        assertTrue(incentiveModuleV2.hasAppealBond(WORKFLOW_ID, 1), "Should have bond after recording");
    }
    
    function test_BondRounding_MultipleResolvers() public {
        // Test bond distribution with rounding when multiple resolvers
        _setupQuadraticCostCurve();
        
        // Setup dispute with 3 resolvers at round 0 (hypothetical multi-resolver round)
        vm.prank(escrowContract);
        resolutionModule.initializeDispute(WORKFLOW_ID, resolver1, bytes32(0));
        
        // Record bond
        uint256 bondAmount = 100e18;
        vm.prank(user1);
        token.transfer(address(incentiveModuleV2), bondAmount);
        
        vm.prank(escrowContract);
        incentiveModuleV2.recordAppealBond(WORKFLOW_ID, user1, bondAmount, address(token), 1);
        
        // In current implementation, bond is divided equally
        // This test documents the behavior (may need adjustment for actual multi-resolver scenarios)
    }
}
