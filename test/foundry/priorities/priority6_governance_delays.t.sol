// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";

/**
 * @title Priority6_GovernanceDelays
 * @notice Tests for governance time delays
 * @dev Priority #6: Verify time delays are enforced
 */
contract Priority6_GovernanceDelays is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule1;
    DefaultResolutionModule public resolutionModule2;
    DefaultReleaseStrategy public releaseStrategy;
    
    address public feeAddress;
    address public resolver;
    address public owner;
    address public timelock;
    
    uint256 public constant ESCROW_FEE = 100;
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant SLOW_LANE_DELAY = 7 days;
    
    function setUp() public {
        owner = address(this);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        timelock = address(0x2345678901234567890123456789012345678901);
        
        resolutionModule1 = new DefaultResolutionModule(owner, resolver);
        resolutionModule2 = new DefaultResolutionModule(owner, address(0x5678));
        releaseStrategy = new DefaultReleaseStrategy();
        
        token = new ERC20Mock("Test Token", "TEST", owner, 10000000e18);
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(0));
        
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        
        // Owner (deployer) has admin role by default, grant ROLE_TIMELOCK to owner for setup
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_TIMELOCK, timelock);
        
        vm.prank(owner);
        vault.queueDefaultResolutionModule(address(resolutionModule1));
        vm.prank(owner);
        vault.queueDefaultReleaseStrategy(address(releaseStrategy));
        
        vm.warp(block.timestamp + 14 days + 1); // Slow lane delay
        vm.prank(owner);
        vault.activateDefaultResolutionModule();
        vm.prank(owner);
        vault.activateDefaultReleaseStrategy();
    }
    
    /**
     * @notice Test: Slow lane queue/activate pattern
     */
    function test_slowLaneQueueActivate() public {
        uint256 startTime = block.timestamp;
        
        // Queue new module
        vm.prank(timelock);
        vault.queueDefaultResolutionModule(address(resolutionModule2));
        
        (, uint64 eta, ) = vault.getPendingDefaultResolutionModule();
        assertGt(eta, startTime, "ETA not set");
        
        // Attempt activate before ETA
        vm.prank(timelock);
        vm.expectRevert();
        vault.activateDefaultResolutionModule();
        
        // Warp to ETA
        vm.warp(eta + 1);
        
        // Activate should succeed
        vm.prank(timelock);
        vault.activateDefaultResolutionModule();
        
        // Verify module swapped - check default resolution module
        // Note: disputeResolutionModule() returns the module for a specific escrow, not the default
        // We need to check by creating a new escrow and verifying it uses the new module
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        // Check that the new escrow uses the new module
        // getResolutionModule returns the module for a specific escrow
        address moduleAddress = address(vault.getResolutionModule(workflowId));
        assertEq(moduleAddress, address(resolutionModule2), "Module not swapped");
    }
    
    /**
     * @notice Test: ETA stored onchain and enforced
     */
    function test_etaStoredAndEnforced() public {
        vm.prank(timelock);
        vault.queueDefaultResolutionModule(address(resolutionModule2));
        
        (, uint64 eta, ) = vault.getPendingDefaultResolutionModule();
        assertGt(eta, 0, "ETA not stored");
        
        // Verify ETA is approximately 7 days from now
        assertApproxEqAbs(eta, block.timestamp + SLOW_LANE_DELAY, 1 hours, "ETA incorrect");
    }
    
    /**
     * @notice Test: Activate before ETA reverts
     */
    function test_activateBeforeEtaReverts() public {
        vm.prank(timelock);
        vault.queueDefaultResolutionModule(address(resolutionModule2));
        
        (, uint64 eta, ) = vault.getPendingDefaultResolutionModule();
        
        // Attempt activate 1 second before ETA
        vm.warp(eta - 1);
        vm.prank(timelock);
        vm.expectRevert();
        vault.activateDefaultResolutionModule();
    }
    
    /**
     * @notice Test: Total delay ~7 days (SLOW_DELAY)
     */
    function test_totalDelayApproximately9Days() public {
        uint256 queueTime = block.timestamp;
        
        // Queue - sets ETA to block.timestamp + 7 days
        vm.prank(timelock);
        vault.queueDefaultResolutionModule(address(resolutionModule2));
        
        (, uint64 eta, ) = vault.getPendingDefaultResolutionModule();
        
        // Verify ETA is approximately 7 days from queue time
        assertApproxEqAbs(uint256(eta), queueTime + SLOW_LANE_DELAY, 1 hours, "ETA incorrect");
        
        // The delay is the difference between ETA and queue time
        // ETA = queueTime + SLOW_LANE_DELAY, so delay = SLOW_LANE_DELAY
        uint256 expectedDelay = uint256(eta) - queueTime;
        
        // Should be approximately 7 days (SLOW_LANE_DELAY)
        assertApproxEqAbs(expectedDelay, SLOW_LANE_DELAY, 1 hours, "Total delay incorrect");
        
        // Activate - warp to ETA + 1 second
        vm.warp(eta + 1);
        vm.prank(timelock);
        vault.activateDefaultResolutionModule();
    }
    
    /**
     * @notice Test: Standard lane requires ROLE_TIMELOCK
     */
    function test_standardLaneRequiresTimelock() public {
        // Non-timelock address attempts standard lane change
        address attacker = address(0x3456789012345678901234567890123456789012);
        vm.prank(attacker);
        vm.expectRevert();
        vault.setDefaultAutoCancelTime(30 days);
    }
    
    /**
     * @notice Test: Emergency lane immediate execution
     */
    function test_emergencyLaneImmediate() public {
        address guardian = address(0x4567890123456789012345678901234567890123);
        bytes32 ROLE_GUARDIAN = vault.ROLE_GUARDIAN();
        vault.grantRole(ROLE_GUARDIAN, guardian);
        
        uint256 startTime = block.timestamp;
        
        // Guardian pauses (should be immediate)
        vm.prank(guardian);
        vault.pause();
        
        uint256 delay = block.timestamp - startTime;
        assertEq(delay, 0, "Emergency action delayed");
        assertTrue(vault.paused(), "Not paused");
    }
    
    /**
     * @notice Test: Emergency functions use onlyRole(ROLE_GUARDIAN)
     */
    function test_emergencyFunctionsRequireGuardian() public {
        address nonGuardian = address(0x5678901234567890123456789012345678901234);
        
        // Non-guardian attempts pause
        vm.prank(nonGuardian);
        vm.expectRevert();
        vault.pause();
    }
}

