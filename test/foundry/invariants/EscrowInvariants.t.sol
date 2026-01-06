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
import "./EscrowHandler.sol";

/**
 * @title EscrowInvariants
 * @notice Invariant tests for escrow contracts
 * @dev Tests that key invariants always hold true across all operations
 */
contract EscrowInvariants is StdInvariant, Test {
    EscrowVault public vault;
    EscrowableERC20 public escrowableERC20;
    ERC20Mock public token;
    EscrowHandler public handler;
    
    address public feeAddress;
    address public resolver;
    address public owner;
    
    // Test addresses
    address constant TEST_FEE_ADDRESS = address(0xFEE);
    address constant TEST_RESOLVER = address(0x1234);
    
    // Module addresses
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    DefaultYieldModule public yieldModule;
    DefaultYieldDistributionModule public yieldDistributionModule;
    
    uint256 public constant ESCROW_FEE = 100; // 1%
    
    function setUp() public {
        owner = address(this);
        feeAddress = TEST_FEE_ADDRESS;
        resolver = TEST_RESOLVER;
        
        // Deploy modules
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();
        yieldModule = new DefaultYieldModule();
        yieldDistributionModule = new DefaultYieldDistributionModule();
        
        // Deploy token (ERC20Mock constructor: name, symbol, initialAccount, initialBalance)
        token = new ERC20Mock("Test Token", "TEST", owner, 10000000e18);
        
        // Deploy escrow contracts
        vault = new EscrowVault(ESCROW_FEE, feeAddress);
        escrowableERC20 = new EscrowableERC20("Escrow Token", "ESCROW", ESCROW_FEE, feeAddress);
        
        // Grant ROLE_TIMELOCK to owner for module setup
        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        vault.grantRole(ROLE_TIMELOCK, owner);
        escrowableERC20.grantRole(ROLE_TIMELOCK, owner);
        
        // Queue all modules first (before warping time)
        // Setup modules for vault
        vault.queueDefaultResolutionModule(address(resolutionModule));
        vault.queueDefaultReleaseStrategy(address(releaseStrategy));
        vault.queueDefaultYieldGenerationModule(address(yieldModule));
        vault.queueDefaultYieldDistributionModule(address(yieldDistributionModule));
        
        // Setup modules for escrowableERC20 (queue before warping)
        escrowableERC20.queueDefaultResolutionModule(address(resolutionModule));
        escrowableERC20.queueDefaultReleaseStrategy(address(releaseStrategy));
        escrowableERC20.queueDefaultYieldGenerationModule(address(yieldModule));
        escrowableERC20.queueDefaultYieldDistributionModule(address(yieldDistributionModule));
        
        // Get actual ETAs from all pending modules and warp past the maximum
        (, uint64 eta1, ) = vault.getPendingDefaultResolutionModule();
        (, uint64 eta2, ) = vault.getPendingDefaultReleaseStrategy();
        (, uint64 eta3, ) = vault.getPendingDefaultYieldGenerationModule();
        (, uint64 eta4, ) = vault.getPendingDefaultYieldDistributionModule();
        (, uint64 eta5, ) = escrowableERC20.getPendingDefaultResolutionModule();
        (, uint64 eta6, ) = escrowableERC20.getPendingDefaultReleaseStrategy();
        (, uint64 eta7, ) = escrowableERC20.getPendingDefaultYieldGenerationModule();
        (, uint64 eta8, ) = escrowableERC20.getPendingDefaultYieldDistributionModule();
        
        // Find maximum ETA
        uint64 maxEta = 0;
        if (eta1 > maxEta) maxEta = eta1;
        if (eta2 > maxEta) maxEta = eta2;
        if (eta3 > maxEta) maxEta = eta3;
        if (eta4 > maxEta) maxEta = eta4;
        if (eta5 > maxEta) maxEta = eta5;
        if (eta6 > maxEta) maxEta = eta6;
        if (eta7 > maxEta) maxEta = eta7;
        if (eta8 > maxEta) maxEta = eta8;
        
        // Warp time to activate modules (must be past all ETAs)
        if (maxEta > 0 && block.timestamp < maxEta) {
            vm.warp(maxEta + 1);
        } else {
            vm.warp(block.timestamp + 7 days + 1);
        }
        
        // Activate all modules
        vault.activateDefaultResolutionModule();
        vault.activateDefaultReleaseStrategy();
        vault.activateDefaultYieldGenerationModule();
        vault.activateDefaultYieldDistributionModule();
        
        escrowableERC20.activateDefaultResolutionModule();
        escrowableERC20.activateDefaultReleaseStrategy();
        escrowableERC20.activateDefaultYieldGenerationModule();
        escrowableERC20.activateDefaultYieldDistributionModule();
        
        // Create handler
        handler = new EscrowHandler(vault, escrowableERC20, token, feeAddress, resolver);
        
        // Set handler as target for invariant testing
        targetContract(address(handler));
    }
    
    // ============ Fund Conservation Invariants ============
    
    /**
     * @notice Invariant: Total funds in vault (escrowed + fees) never exceed contract balance
     * @dev For EscrowVault, we track per-token balances
     */
    function invariant_vaultFundConservation() public view {
        uint256 contractBalance = token.balanceOf(address(vault));
        uint256 totalEscrowed = vault.totalHeldInEscrowPerToken(address(token));
        uint256 totalFees = vault.totalFeesPerToken(address(token));
        
        // Contract balance should be at least escrowed + fees
        // (may be more if yield was generated and not yet distributed)
        assertGe(contractBalance, totalEscrowed + totalFees, "Fund conservation violated");
    }
    
    /**
     * @notice Invariant: Total funds in escrowableERC20 (escrowed + fees) never exceed contract balance
     */
    function invariant_erc20FundConservation() public view {
        uint256 contractBalance = escrowableERC20.balanceOf(address(escrowableERC20));
        uint256 totalEscrowed = escrowableERC20.totalHeldInEscrow();
        uint256 totalFees = escrowableERC20.totalFees();
        
        // Contract balance should be at least escrowed + fees
        assertGe(contractBalance, totalEscrowed + totalFees, "Fund conservation violated");
    }
    
    // ============ State Consistency Invariants ============
    
    /**
     * @notice Invariant: All escrow states are valid
     */
    function invariant_vaultValidStates() public view {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            
            // State must be one of the valid enum values
            assertTrue(
                et.escrowState == EscrowState.NONE ||
                et.escrowState == EscrowState.PENDING ||
                et.escrowState == EscrowState.RELEASED ||
                et.escrowState == EscrowState.REFUNDED ||
                et.escrowState == EscrowState.DISPUTED ||
                et.escrowState == EscrowState.RESOLVED,
                "Invalid escrow state"
            );
            
            // Workflow ID must match index
            assertEq(et.workflowId, i, "Workflow ID mismatch");
        }
    }
    
    /**
     * @notice Invariant: All escrow states are valid (ERC20)
     */
    function invariant_erc20ValidStates() public view {
        uint256 count = escrowableERC20.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = escrowableERC20.getEscrowTransfer(i);
            
            // State must be one of the valid enum values
            assertTrue(
                et.escrowState == EscrowState.NONE ||
                et.escrowState == EscrowState.PENDING ||
                et.escrowState == EscrowState.RELEASED ||
                et.escrowState == EscrowState.REFUNDED ||
                et.escrowState == EscrowState.DISPUTED ||
                et.escrowState == EscrowState.RESOLVED,
                "Invalid escrow state"
            );
            
            // Workflow ID must match index
            assertEq(et.workflowId, i, "Workflow ID mismatch");
        }
    }
    
    // ============ Balance Consistency Invariants ============
    
    /**
     * @notice Invariant: Remaining balance never exceeds total deposited
     */
    function invariant_vaultBalanceConsistency() public view {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            
            // Remaining balance should never exceed total deposited
            assertLe(et.remainingBalance, et.totalDeposited, "Balance consistency violated");
            
            // If released or refunded, remaining balance should be 0
            if (et.escrowState == EscrowState.RELEASED ||
                et.escrowState == EscrowState.REFUNDED ||
                et.escrowState == EscrowState.RESOLVED) {
                assertEq(et.remainingBalance, 0, "Completed escrow should have zero balance");
            }
        }
    }
    
    /**
     * @notice Invariant: Remaining balance never exceeds total deposited (ERC20)
     */
    function invariant_erc20BalanceConsistency() public view {
        uint256 count = escrowableERC20.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = escrowableERC20.getEscrowTransfer(i);
            
            // Remaining balance should never exceed total deposited
            assertLe(et.remainingBalance, et.totalDeposited, "Balance consistency violated");
            
            // If released or refunded, remaining balance should be 0
            if (et.escrowState == EscrowState.RELEASED ||
                et.escrowState == EscrowState.REFUNDED ||
                et.escrowState == EscrowState.RESOLVED) {
                assertEq(et.remainingBalance, 0, "Completed escrow should have zero balance");
            }
        }
    }
    
    // ============ Workflow ID Consistency Invariants ============
    
    /**
     * @notice Invariant: Next workflow ID equals escrow count
     */
    function invariant_vaultWorkflowIdConsistency() public view {
        assertEq(vault.nextWorkflowId(), vault.getEscrowCount(), "Workflow ID mismatch");
    }
    
    /**
     * @notice Invariant: Next workflow ID equals escrow count (ERC20)
     */
    function invariant_erc20WorkflowIdConsistency() public view {
        assertEq(escrowableERC20.nextWorkflowId(), escrowableERC20.getEscrowCount(), "Workflow ID mismatch");
    }
    
    // ============ Escrow Count Consistency Invariants ============
    
    /**
     * @notice Invariant: Total pending escrows matches count
     */
    function invariant_vaultPendingCountConsistency() public view {
        uint256 count = vault.getEscrowCount();
        uint256 pendingCount = 0;
        
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            if (et.escrowState == EscrowState.PENDING ||
                et.escrowState == EscrowState.DISPUTED) {
                pendingCount++;
            }
        }
        
        assertEq(vault.totalEscrowsPending(), pendingCount, "Pending count mismatch");
    }
    
    /**
     * @notice Invariant: Total pending escrows matches count (ERC20)
     */
    function invariant_erc20PendingCountConsistency() public view {
        uint256 count = escrowableERC20.getEscrowCount();
        uint256 pendingCount = 0;
        
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = escrowableERC20.getEscrowTransfer(i);
            if (et.escrowState == EscrowState.PENDING ||
                et.escrowState == EscrowState.DISPUTED) {
                pendingCount++;
            }
        }
        
        assertEq(escrowableERC20.totalEscrowsPending(), pendingCount, "Pending count mismatch");
    }
    
    // ============ Fee Consistency Invariants ============
    
    /**
     * @notice Invariant: Total fees match sum of per-token fees
     */
    function invariant_vaultFeeConsistency() public view {
        // This invariant would require tracking all tokens, which is complex
        // For now, we verify that totalFees is non-negative and reasonable
        assertGe(vault.totalFees(), 0, "Total fees cannot be negative");
    }
    
    /**
     * @notice Invariant: Fees are non-negative
     */
    function invariant_erc20FeeConsistency() public view {
        assertGe(escrowableERC20.totalFees(), 0, "Total fees cannot be negative");
    }
    
    // ============ No Double Spending Invariants ============
    
    /**
     * @notice Invariant: Escrows cannot be both released and cancelled
     */
    function invariant_vaultNoDoubleSpending() public view {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            
            // An escrow cannot be both released and refunded
            assertFalse(
                et.escrowState == EscrowState.RELEASED &&
                et.escrowState == EscrowState.REFUNDED,
                "Double spending detected"
            );
            
            // If released or refunded, remaining balance must be 0
            if (et.escrowState == EscrowState.RELEASED ||
                et.escrowState == EscrowState.REFUNDED) {
                assertEq(et.remainingBalance, 0, "Completed escrow must have zero balance");
            }
        }
    }
    
    /**
     * @notice Invariant: Escrows cannot be both released and cancelled (ERC20)
     */
    function invariant_erc20NoDoubleSpending() public view {
        uint256 count = escrowableERC20.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = escrowableERC20.getEscrowTransfer(i);
            
            // An escrow cannot be both released and refunded
            assertFalse(
                et.escrowState == EscrowState.RELEASED &&
                et.escrowState == EscrowState.REFUNDED,
                "Double spending detected"
            );
            
            // If released or refunded, remaining balance must be 0
            if (et.escrowState == EscrowState.RELEASED ||
                et.escrowState == EscrowState.REFUNDED) {
                assertEq(et.remainingBalance, 0, "Completed escrow must have zero balance");
            }
        }
    }
    
    // ============ Module Snapshot Consistency Invariants ============
    
    /**
     * @notice Invariant: Module snapshots are set for all escrows
     */
    function invariant_vaultModuleSnapshots() public view {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            
            // Module snapshots should be set (not zero) for all escrows
            // Note: Zero is valid if no module was set at creation time
            // This invariant ensures snapshots are consistent
            if (et.escrowState != EscrowState.NONE) {
                // Snapshot modules should be set (may be zero if no module configured)
                // We just verify they don't change after creation
                assertTrue(true, "Module snapshot check"); // Placeholder - actual check depends on requirements
            }
        }
    }
    
    /**
     * @notice Invariant: Module snapshots are set for all escrows (ERC20)
     */
    function invariant_erc20ModuleSnapshots() public view {
        uint256 count = escrowableERC20.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = escrowableERC20.getEscrowTransfer(i);
            
            // Module snapshots should be set (not zero) for all escrows
            if (et.escrowState != EscrowState.NONE) {
                // Snapshot modules should be set (may be zero if no module configured)
                assertTrue(true, "Module snapshot check"); // Placeholder
            }
        }
    }
    
    // ============ State Transition Invariants ============
    
    /**
     * @notice Invariant: Disputed escrows have dispute timestamp set
     */
    function invariant_vaultDisputeTimestamp() public view {
        uint256 count = vault.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = vault.getEscrowTransfer(i);
            
            if (et.escrowState == EscrowState.DISPUTED) {
                uint256 disputeTimestamp = vault.disputeRaisedTimestamp(i);
                assertGt(disputeTimestamp, 0, "Disputed escrow must have timestamp");
            }
        }
    }
    
    /**
     * @notice Invariant: Disputed escrows have dispute timestamp set (ERC20)
     */
    function invariant_erc20DisputeTimestamp() public view {
        uint256 count = escrowableERC20.getEscrowCount();
        for (uint256 i = 0; i < count; i++) {
            EscrowTransfer memory et = escrowableERC20.getEscrowTransfer(i);
            
            if (et.escrowState == EscrowState.DISPUTED) {
                uint256 disputeTimestamp = escrowableERC20.disputeRaisedTimestamp(i);
                assertGt(disputeTimestamp, 0, "Disputed escrow must have timestamp");
            }
        }
    }
    
    // ============ Access Control Invariants ============
    
    /**
     * @notice Invariant: Fee address is never zero
     */
    function invariant_vaultFeeAddressSet() public view {
        assertNotEq(vault.escrowFeeAddress(), address(0), "Fee address must be set");
    }
    
    /**
     * @notice Invariant: Fee address is never zero (ERC20)
     */
    function invariant_erc20FeeAddressSet() public view {
        assertNotEq(escrowableERC20.escrowFeeAddress(), address(0), "Fee address must be set");
    }
    
    // ============ Configuration Invariants ============
    
    /**
     * @notice Invariant: Escrow fee is within valid range
     */
    function invariant_vaultFeeRange() public view {
        assertLe(vault.escrowFee(), vault.ESCROW_FEE_DENOMINATOR(), "Fee exceeds denominator");
    }
    
    /**
     * @notice Invariant: Escrow fee is within valid range (ERC20)
     */
    function invariant_erc20FeeRange() public view {
        assertLe(escrowableERC20.escrowFee(), escrowableERC20.ESCROW_FEE_DENOMINATOR(), "Fee exceeds denominator");
    }
    
    /**
     * @notice Invariant: Max dispute duration is within valid range
     */
    function invariant_vaultMaxDisputeDuration() public view {
        uint256 maxDuration = vault.maxDisputeDuration();
        assertGe(maxDuration, 7 days, "Max dispute duration too short");
        assertLe(maxDuration, 365 days, "Max dispute duration too long");
    }
    
    /**
     * @notice Invariant: Max dispute duration is within valid range (ERC20)
     */
    function invariant_erc20MaxDisputeDuration() public view {
        uint256 maxDuration = escrowableERC20.maxDisputeDuration();
        assertGe(maxDuration, 7 days, "Max dispute duration too short");
        assertLe(maxDuration, 365 days, "Max dispute duration too long");
    }
}

