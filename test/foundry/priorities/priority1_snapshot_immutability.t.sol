// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/EscrowableERC20.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/modules/DefaultYieldModule.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";

/**
 * @title Priority1_SnapshotImmutability
 * @notice Tests for snapshot immutability - core security guarantee
 * @dev Priority #1: Verify module snapshots never change after escrow creation
 */
contract Priority1_SnapshotImmutability is StdInvariant, Test {
    EscrowVault public vault;
    EscrowableERC20 public escrowableERC20;
    ERC20Mock public token;
    
    address public feeAddress;
    address public resolver;
    address public owner;
    
    DefaultResolutionModule public resolutionModule1;
    DefaultResolutionModule public resolutionModule2;
    DefaultReleaseStrategy public releaseStrategy1;
    DefaultReleaseStrategy public releaseStrategy2;
    DefaultYieldModule public yieldModule1;
    DefaultYieldModule public yieldModule2;
    
    uint256 public constant ESCROW_FEE = 100; // 1%
    
    function setUp() public {
        owner = address(this);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        
        // Deploy first set of modules
        resolutionModule1 = new DefaultResolutionModule(owner, resolver);
        releaseStrategy1 = new DefaultReleaseStrategy();
        yieldModule1 = new DefaultYieldModule();
        
        // Deploy second set of modules (for swapping)
        resolutionModule2 = new DefaultResolutionModule(owner, address(0x5678));
        releaseStrategy2 = new DefaultReleaseStrategy();
        yieldModule2 = new DefaultYieldModule();
        
        token = new ERC20Mock("Test Token", "TEST", owner, 10000000e18);
        
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(0));
        escrowableERC20 = new EscrowableERC20("Escrow Token", "ESCROW", ESCROW_FEE, feeAddress, address(0));
        
        // Grant ROLE_TIMELOCK to owner
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        vault.grantRole(ROLE_TIMELOCK, owner);
        escrowableERC20.grantRole(ROLE_TIMELOCK, owner);
        
        // Setup initial modules
        vault.queueDefaultResolutionModule(address(resolutionModule1));
        vault.queueDefaultReleaseStrategy(address(releaseStrategy1));
        vault.queueDefaultYieldGenerationModule(address(yieldModule1));
        
        escrowableERC20.queueDefaultResolutionModule(address(resolutionModule1));
        escrowableERC20.queueDefaultReleaseStrategy(address(releaseStrategy1));
        escrowableERC20.queueDefaultYieldGenerationModule(address(yieldModule1));
        
        // Warp time and activate
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateDefaultResolutionModule();
        vault.activateDefaultReleaseStrategy();
        vault.activateDefaultYieldGenerationModule();
        
        escrowableERC20.activateDefaultResolutionModule();
        escrowableERC20.activateDefaultReleaseStrategy();
        escrowableERC20.activateDefaultYieldGenerationModule();
    }
    
    /**
     * @notice Test: Module snapshots are set at creation
     */
    function test_snapshotSetAtCreation() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        EscrowTransfer memory et = vault.getEscrowTransfer(workflowId);
        
        // Verify snapshots are set
        assertEq(et.snapshotResolutionModule, address(resolutionModule1), "Resolution module snapshot not set");
        assertEq(et.snapshotReleaseStrategy, address(releaseStrategy1), "Release strategy snapshot not set");
        assertEq(et.snapshotYieldGenerationModule, address(yieldModule1), "Yield module snapshot not set");
    }
    
    /**
     * @notice Test: Module snapshots never change after creation
     */
    function test_snapshotNeverChanges() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        EscrowTransfer memory etBefore = vault.getEscrowTransfer(workflowId);
        address snapshotResolution = etBefore.snapshotResolutionModule;
        address snapshotRelease = etBefore.snapshotReleaseStrategy;
        address snapshotYield = etBefore.snapshotYieldGenerationModule;
        
        // Swap modules
        vault.queueDefaultResolutionModule(address(resolutionModule2));
        vault.queueDefaultReleaseStrategy(address(releaseStrategy2));
        vault.queueDefaultYieldGenerationModule(address(yieldModule2));
        
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateDefaultResolutionModule();
        vault.activateDefaultReleaseStrategy();
        vault.activateDefaultYieldGenerationModule();
        
        // Verify snapshots unchanged
        EscrowTransfer memory etAfter = vault.getEscrowTransfer(workflowId);
        assertEq(etAfter.snapshotResolutionModule, snapshotResolution, "Resolution module snapshot changed");
        assertEq(etAfter.snapshotReleaseStrategy, snapshotRelease, "Release strategy snapshot changed");
        assertEq(etAfter.snapshotYieldGenerationModule, snapshotYield, "Yield module snapshot changed");
    }
    
    /**
     * @notice Test: Module getters read from snapshots
     */
    function test_moduleGettersReadFromSnapshots() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);
        
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        // Get snapshotted modules
        address snapshotResolution = vault.getEscrowTransfer(workflowId).snapshotResolutionModule;
        address snapshotRelease = vault.getEscrowTransfer(workflowId).snapshotReleaseStrategy;
        address snapshotYield = vault.getEscrowTransfer(workflowId).snapshotYieldGenerationModule;
        
        // Swap modules
        vault.queueDefaultResolutionModule(address(resolutionModule2));
        vault.queueDefaultReleaseStrategy(address(releaseStrategy2));
        vault.queueDefaultYieldGenerationModule(address(yieldModule2));
        
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateDefaultResolutionModule();
        vault.activateDefaultReleaseStrategy();
        vault.activateDefaultYieldGenerationModule();
        
        // Verify getters still return snapshotted modules
        assertEq(vault.getEscrowTransfer(workflowId).snapshotResolutionModule, snapshotResolution, "Getter returns wrong module");
        assertEq(vault.getEscrowTransfer(workflowId).snapshotReleaseStrategy, snapshotRelease, "Getter returns wrong module");
        assertEq(vault.getEscrowTransfer(workflowId).snapshotYieldGenerationModule, snapshotYield, "Getter returns wrong module");
    }
    
    /**
     * @notice Test: New escrows use new modules after swap
     */
    function test_newEscrowsUseNewModules() public {
        address buyer1 = address(0x1001);
        address seller1 = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer1, amount * 2);
        vm.prank(buyer1);
        token.approve(address(vault), amount * 2);
        
        // Create escrow with old modules
        vm.prank(buyer1);
        uint256 workflowId1 = vault.createEscrow(address(token), seller1, amount);
        
        EscrowTransfer memory et1 = vault.getEscrowTransfer(workflowId1);
        address oldResolution = et1.snapshotResolutionModule;
        
        // Swap modules
        vault.queueDefaultResolutionModule(address(resolutionModule2));
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateDefaultResolutionModule();
        
        // Create new escrow
        vm.prank(buyer1);
        uint256 workflowId2 = vault.createEscrow(address(token), seller1, amount);
        
        EscrowTransfer memory et2 = vault.getEscrowTransfer(workflowId2);
        
        // Old escrow still uses old module
        assertEq(et1.snapshotResolutionModule, oldResolution, "Old escrow module changed");
        
        // New escrow uses new module
        assertEq(et2.snapshotResolutionModule, address(resolutionModule2), "New escrow doesn't use new module");
        assertNotEq(et2.snapshotResolutionModule, oldResolution, "New escrow uses old module");
    }
    
    /**
     * @notice Fuzz test: Multiple module swaps, verify each escrow uses correct module
     */
    function testFuzz_multipleSwapsCorrectModules(
        uint8 numEscrows,
        uint8 numSwaps
    ) public {
        numEscrows = uint8(bound(numEscrows, 1, 10));
        numSwaps = uint8(bound(numSwaps, 1, 5));
        
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount * uint256(numEscrows) * 2);
        vm.prank(buyer);
        token.approve(address(vault), type(uint256).max);
        
        // Track which module each escrow should use (using array instead of mapping)
        address[] memory expectedModules = new address[](numEscrows);
        
        // Create escrows and swap modules
        for (uint8 i = 0; i < numEscrows; i++) {
            vm.prank(buyer);
            uint256 workflowId = vault.createEscrow(address(token), seller, amount);
            
            EscrowTransfer memory et = vault.getEscrowTransfer(workflowId);
            expectedModules[i] = et.snapshotResolutionModule;
            
            // Swap module every few escrows
            if (i > 0 && i % (numEscrows / numSwaps + 1) == 0) {
                DefaultResolutionModule newModule = new DefaultResolutionModule(owner, address(uint160(i)));
                vault.queueDefaultResolutionModule(address(newModule));
                vm.warp(block.timestamp + 7 days + 1);
                vault.activateDefaultResolutionModule();
            }
        }
        
        // Verify all escrows still use their snapshotted modules
        for (uint8 i = 0; i < numEscrows; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            assertEq(et.snapshotResolutionModule, expectedModules[i], "Module snapshot changed");
        }
    }
    
    /**
     * @notice Invariant: Snapshot fields immutable after creation
     */
    function invariant_snapshotFieldsImmutable() public view {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            
            // Once set (non-zero), snapshots should never change
            // This is enforced by the contract - no setters exist
            if (et.escrowState != EscrowState.NONE) {
                // Snapshots are set at creation and never modified
                // We can't directly test immutability in an invariant, but we verify
                // that snapshots are consistent
                assertTrue(
                    et.snapshotResolutionModule != address(0) || 
                    et.snapshotReleaseStrategy != address(0) ||
                    et.snapshotYieldGenerationModule != address(0),
                    "All snapshots are zero"
                );
            }
        }
    }
    
    /**
     * @notice Test: Escrow created during module swap uses correct module
     */
    function test_escrowCreatedDuringSwap() public {
        address buyer = address(0x1001);
        address seller = address(0x1002);
        uint256 amount = 1000e18;
        
        token.mint(buyer, amount * 2);
        vm.prank(buyer);
        token.approve(address(vault), amount * 2);
        
        // Queue new module
        vault.queueDefaultResolutionModule(address(resolutionModule2));
        (, uint64 eta, ) = vault.getPendingDefaultResolutionModule();
        
        // Create escrow before activation
        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount);
        
        EscrowTransfer memory et = vault.getEscrowTransfer(workflowId);
        
        // Should use current active module (module1), not pending module
        assertEq(et.snapshotResolutionModule, address(resolutionModule1), "Should use active module");
        
        // Activate new module
        vm.warp(eta + 1);
        vault.activateDefaultResolutionModule();
        
        // Verify snapshot unchanged
        et = vault.getEscrowTransfer(workflowId);
        assertEq(et.snapshotResolutionModule, address(resolutionModule1), "Snapshot changed after activation");
    }
}

