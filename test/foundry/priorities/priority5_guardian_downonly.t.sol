// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/modules/AaveYieldGenerationModule.sol";
import "../../../contracts/mocks/MockAavePool.sol";

/**
 * @title Priority5_GuardianDownOnly
 * @notice Tests for guardian down-only powers
 * @dev Priority #5: Verify guardian cannot increase risk
 */
contract Priority5_GuardianDownOnly is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    AaveYieldGenerationModule public yieldModule;
    MockAavePool public aavePool;
    
    address public feeAddress;
    address public resolver;
    address public owner;
    address public guardian;
    address public timelock;
    
    uint256 public constant ESCROW_FEE = 100;
    uint256 public constant TOKEN_CAP = 100000e18;
    uint256 public constant GLOBAL_CAP = 500000e18;
    
    function setUp() public {
        owner = address(this);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        guardian = address(0x1234567890123456789012345678901234567890);
        timelock = address(0x2345678901234567890123456789012345678901);
        
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();
        
        aavePool = new MockAavePool();
        ERC20Mock aToken = new ERC20Mock("aToken", "aTKN", address(aavePool), 0);
        yieldModule = new AaveYieldGenerationModule(owner);
        
        token = new ERC20Mock("Test Token", "TEST", owner, 10000000e18);
        vault = new EscrowVault(ESCROW_FEE, feeAddress);
        
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        bytes32 ROLE_GUARDIAN = vault.ROLE_GUARDIAN();
        bytes32 YIELD_ROLE_TIMELOCK = yieldModule.ROLE_TIMELOCK();
        bytes32 YIELD_ROLE_GUARDIAN = yieldModule.ROLE_GUARDIAN();
        
        // Owner (deployer) has admin role by default, grant ROLE_TIMELOCK to owner for setup
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_TIMELOCK, timelock);
        vault.grantRole(ROLE_GUARDIAN, guardian);
        yieldModule.grantRole(YIELD_ROLE_TIMELOCK, owner);
        yieldModule.grantRole(YIELD_ROLE_TIMELOCK, timelock);
        yieldModule.grantRole(YIELD_ROLE_GUARDIAN, guardian);
        
        vm.prank(owner);
        vault.queueDefaultResolutionModule(address(resolutionModule));
        vm.prank(owner);
        vault.queueDefaultReleaseStrategy(address(releaseStrategy));
        vault.queueDefaultYieldGenerationModule(address(yieldModule));
        
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateDefaultResolutionModule();
        vault.activateDefaultReleaseStrategy();
        vault.activateDefaultYieldGenerationModule();
        
        // Set initial caps (on yieldModule, not vault)
        vm.prank(timelock);
        yieldModule.setTokenCap(address(token), TOKEN_CAP);
        vm.prank(timelock);
        yieldModule.setGlobalCap(address(token), GLOBAL_CAP);
    }
    
    /**
     * @notice Test: Guardian cannot raise token cap
     */
    function test_guardianCannotRaiseTokenCap() public {
        uint256 currentCap = yieldModule.tokenCap(address(token));
        
        // Guardian attempts to raise cap
        vm.prank(guardian);
        vm.expectRevert();
        yieldModule.guardianLowerTokenCap(address(token), currentCap + 1e18);
        
        // Guardian can lower cap
        vm.prank(guardian);
        yieldModule.guardianLowerTokenCap(address(token), currentCap - 1e18);
        
        assertEq(yieldModule.tokenCap(address(token)), currentCap - 1e18, "Cap not lowered");
    }
    
    /**
     * @notice Test: Guardian cannot raise global cap
     */
    function test_guardianCannotRaiseGlobalCap() public {
        uint256 currentCap = yieldModule.globalCap(address(token));
        
        // Guardian attempts to raise cap
        vm.prank(guardian);
        vm.expectRevert();
        yieldModule.guardianLowerGlobalCap(address(token), currentCap + 1e18);
        
        // Guardian can lower cap
        vm.prank(guardian);
        yieldModule.guardianLowerGlobalCap(address(token), currentCap - 1e18);
        
        assertEq(yieldModule.globalCap(address(token)), currentCap - 1e18, "Global cap not lowered");
    }
    
    /**
     * @notice Test: Guardian cannot unpause
     */
    function test_guardianCannotUnpause() public {
        // Guardian pauses
        vm.prank(guardian);
        vault.pause();
        
        assertTrue(vault.paused(), "Not paused");
        
        // Guardian attempts to unpause
        vm.prank(guardian);
        vm.expectRevert(); // Should revert - requires ROLE_TIMELOCK
        vault.unpause();
        
        // Timelock can unpause
        vm.prank(timelock);
        vault.unpause();
        
        assertFalse(vault.paused(), "Still paused");
    }
    
    /**
     * @notice Test: Guardian cannot enable Aave
     */
    function test_guardianCannotEnableAave() public {
        // Configure Aave pool first (required before enabling)
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        yieldModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        yieldModule.activateAavePoolProvider();
        
        // Register token and set up aToken
        MockAToken aToken = new MockAToken(address(token), "aToken", "aTKN");
        aToken.setPool(address(aavePool));
        aavePool.setAToken(address(token), address(aToken));
        yieldModule.registerTokenForAave(address(token), address(aToken));
        
        // Enable Aave first (via timelock)
        vm.prank(timelock);
        yieldModule.setAaveEnabled(true);
        
        // Guardian disables Aave
        vm.prank(guardian);
        yieldModule.guardianDisableAave();
        
        // Guardian attempts to enable Aave
        vm.prank(guardian);
        vm.expectRevert(); // Should revert - requires ROLE_TIMELOCK
        yieldModule.setAaveEnabled(true);
        
        // Timelock can enable Aave
        vm.prank(timelock);
        yieldModule.setAaveEnabled(true);
    }
    
    /**
     * @notice Test: Guardian can lower cap to same value (edge case)
     */
    function test_guardianCanLowerCapToSameValue() public {
        uint256 currentCap = yieldModule.tokenCap(address(token));
        
        // Guardian can set cap to same value (no-op)
        vm.prank(guardian);
        yieldModule.guardianLowerTokenCap(address(token), currentCap);
        
        assertEq(yieldModule.tokenCap(address(token)), currentCap, "Cap changed");
    }
    
    /**
     * @notice Fuzz test: Guardian cannot raise caps
     */
    function testFuzz_guardianCannotRaiseCaps(uint256 newCap) public {
        uint256 currentCap = yieldModule.tokenCap(address(token));
        newCap = bound(newCap, currentCap + 1, type(uint256).max);
        
        vm.prank(guardian);
        vm.expectRevert();
        yieldModule.guardianLowerTokenCap(address(token), newCap);
    }
    
    /**
     * @notice Test: Guardian doesn't have ROLE_TIMELOCK
     */
    function test_guardianNoTimelockRole() public {
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        
        assertFalse(vault.hasRole(ROLE_TIMELOCK, guardian), "Guardian has timelock role");
        assertTrue(vault.hasRole(ROLE_TIMELOCK, timelock), "Timelock doesn't have role");
    }
    
    /**
     * @notice Test: Guardian can pause but not unpause
     */
    function test_guardianPauseUnpause() public {
        // Guardian can pause
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused(), "Not paused");
        
        // Guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert();
        vault.unpause();
        
        // Verify still paused
        assertTrue(vault.paused(), "Unpaused by guardian");
    }
}

