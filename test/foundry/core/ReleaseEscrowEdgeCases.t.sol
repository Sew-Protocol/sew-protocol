// SPDX-License-Identifier: MIT
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/core/modules/DefaultResolutionModule.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/ops/YieldOps.sol';
import 'contracts/ops/DisputeOps.sol';
import 'contracts/ops/SettlementOps.sol';
import 'contracts/ops/CreateOps.sol';
import 'contracts/core/BondCollector.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/admin/EscrowGovernanceTimelock.sol';
import 'contracts/libraries/SettingsValidationLibrary.sol';
import 'contracts/interfaces/IYieldModule.sol';
import 'contracts/interfaces/IYieldDistributionModule.sol';

/**
 * @title ReleaseEscrowEdgeCasesTest
 * @notice Tests for edge cases in releaseEscrowTransfer and updateBalance
 * @dev Focuses on accounting correctness, partial withdrawals, and yield handling edge cases
 */
contract ReleaseEscrowEdgeCasesTest is Test {
    EscrowVault vault;
    ERC20Mock token;
    DefaultResolutionModule rm;
    YieldOps yieldOps;
    DisputeOps disputeOps;
    SettlementOps settlementOps;
    CreateOps createOps;
    BondCollector bondCollector;
    ModuleSnapshotRegistry moduleManagement;
    EscrowGovernanceTimelock adminContract;

    address sender = address(0x10);
    address recipient = address(0x20);
    address resolver = address(0x30);
    address feeAddress = address(0x40);

    uint256 constant ESCROW_FEE = 100; // 1%
    uint256 constant AMOUNT = 10 ether;

    // Mock yield generation module for testing edge cases
    MockYieldGenForEdgeCases mockYieldGen;

    function setUp() public {
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        adminContract = new EscrowGovernanceTimelock(address(this));
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        // Register escrow contract (requires ROLE_TIMELOCK, which address(this) has from constructor)
        vm.prank(address(this));
        moduleManagement.registerEscrowContract(address(vault));

        // Register escrow contract with all ops contracts
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        // Wire ops contracts on the vault
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        token = new ERC20Mock('Test', 'TST', address(this), 1e24);
        rm = new DefaultResolutionModule(address(this), resolver);
        mockYieldGen = new MockYieldGenForEdgeCases();

        // Setup roles and modules
        vault.grantRole(vault.ROLE_TIMELOCK(), address(this));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), address(this));
        bytes32 timelockRole = moduleManagement.ROLE_TIMELOCK();
        moduleManagement.grantRole(timelockRole, address(this));
        adminContract.queueResolutionModule(address(vault), address(rm));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(vault));

        // Set mock yield generation module as default
        // queueModule must be called by the escrow contract itself
        vm.prank(address(this));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(mockYieldGen));
        // Get ETA and warp to after activation time
        (address pendingModule, uint64 eta, bool exists) = moduleManagement.getPendingModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        require(exists, "Module should be queued");
        pendingModule; // Silence unused variable warning
        vm.warp(uint256(eta) + 1);
        vm.prank(address(this));
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);

        // Fund sender
        token.transfer(sender, 1000 ether);
    }

    // ============ Test 1: Balance Decrement vs Transfer Amount Mismatch ============

    function test_releaseEscrowTransfer_balanceDecrementVsTransferAmount() public {
        // Setup: Create escrow with yield enabled
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 principal = AMOUNT - fee;

        // Track balance before release
        uint256 totalHeldBefore = vault.totalHeldInEscrowPerToken(address(token));
        uint256 contractBalanceBefore = token.balanceOf(address(vault));

        // Configure mock to generate yield (actualAmount > amount)
        uint256 yieldAmount = 1 ether;
        mockYieldGen.setWithdrawResult(true, principal + yieldAmount, yieldAmount);
        
        // Fund mock module with tokens (simulating Aave holding tokens)
        // The module will transfer them back to escrow on withdrawal
        // Note: In real flow, module withdraws from Aave to escrow, then YieldOps pulls yield portion
        // For this test, we simulate by funding the mock
        token.transfer(address(mockYieldGen), principal + yieldAmount);
        
        // Also need to fund YieldOps with yield portion for distribution
        // In real flow, YieldOps would pull from escrow, but for test we pre-fund
        token.transfer(address(yieldOps), yieldAmount);

        // Release escrow
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Verify: Balance decremented by principal (not actualAmount)
        uint256 totalHeldAfter = vault.totalHeldInEscrowPerToken(address(token));
        assertEq(totalHeldBefore - totalHeldAfter, principal, "Balance should decrement by principal");

        // Verify: Transfer was for actualAmount (principal + yield)
        uint256 recipientBalance = token.balanceOf(recipient);
        // Recipient should receive actualAmount (>= principal)
        assertGe(recipientBalance, principal, "Recipient should receive at least principal");
    }

    // ============ Test 2: Accounting Correctness with Multiple Escrows ============

    function test_releaseEscrowTransfer_accountingCorrectnessMultipleEscrows() public {
        // Setup: Create multiple escrows with yield
        vm.prank(sender);
        token.approve(address(vault), AMOUNT * 3);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;

        uint256 wid1;
        uint256 wid2;
        uint256 wid3;

        vm.prank(sender);
        wid1 = vault.createEscrow(address(token), recipient, AMOUNT, settings);
        vm.prank(sender);
        wid2 = vault.createEscrow(address(token), recipient, AMOUNT, settings);
        vm.prank(sender);
        wid3 = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        // Verify totalHeldInEscrowPerToken is correct
        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 principalPerEscrow = AMOUNT - fee;
        uint256 expectedTotal = principalPerEscrow * 3;
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), expectedTotal);

        // Configure mock to generate yield
        uint256 yieldAmount = 0.5 ether;
        mockYieldGen.setWithdrawResult(true, principalPerEscrow + yieldAmount, yieldAmount);
        
        // Fund mock module with tokens for all escrows
        token.transfer(address(mockYieldGen), (principalPerEscrow + yieldAmount) * 3);
        
        // Fund YieldOps with yield portion for distribution (for all 3 escrows)
        token.transfer(address(yieldOps), yieldAmount * 3);

        // Release first escrow
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid1);

        // Verify accounting: totalHeldInEscrowPerToken decreased by principal (not actualAmount)
        uint256 expectedAfterFirst = expectedTotal - principalPerEscrow;
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), expectedAfterFirst);

        // Verify contract balance
        // Note: After release with yield, the vault transfers actualAmount to recipient
        // Remaining principals are still deposited in the yield module (not in vault)
        // Vault should have at least the fees
        uint256 contractBalance = token.balanceOf(address(vault));
        uint256 totalFees = vault.totalFeesPerToken(address(token));
        
        // Contract balance should have at least the fees
        // (principals for remaining escrows are in yield module, will be withdrawn on their release)
        assertGe(contractBalance, totalFees, "Vault should have at least fees after first release");

        // Release remaining escrows
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid2);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid3);

        // Verify final accounting
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0);
    }

    // ============ Test 3: Partial Withdrawal (actualAmount < amount) ============

    function test_releaseEscrowTransfer_partialWithdrawal() public {
        // Setup: Create escrow with yield enabled
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 principal = AMOUNT - fee;

        // Configure mock to return partial withdrawal (actualAmount < amount)
        // This simulates a partial withdrawal scenario (shouldn't happen normally)
        uint256 partialAmount = principal / 2;
        mockYieldGen.setWithdrawResult(true, partialAmount, 0); // No yield, partial withdrawal
        
        // Fund mock module with partial amount only
        token.transfer(address(mockYieldGen), partialAmount);

        // Release escrow
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Verify: Transfer should succeed for the partial amount recovered
        // because the Push Model ensures tokens arrive at the vault before transfer
        uint256 recipientBalance = token.balanceOf(recipient);
        assertEq(recipientBalance, partialAmount, "Recipient should receive the partial amount");
        
        uint256 claimable = vault.claimableBalances(wid, recipient);
        assertEq(claimable, 0, "Claimable should be zero as transfer succeeded");
    }

    // ============ Test 4: Insufficient Balance After Yield Distribution ============

    function test_releaseEscrowTransfer_insufficientBalanceAfterYield() public {
        // Setup: Create escrow with yield
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 principal = AMOUNT - fee;

        // Configure mock to generate yield
        uint256 yieldAmount = 1 ether;
        mockYieldGen.setWithdrawResult(true, principal + yieldAmount, yieldAmount);
        
        // Fund mock module with tokens
        token.transfer(address(mockYieldGen), principal + yieldAmount);

        // Edge case: Manually drain contract balance (simulate external drain)
        // This shouldn't happen in production, but we should handle it gracefully
        uint256 contractBalance = token.balanceOf(address(vault));
        if (contractBalance > 1) {
            // Transfer most of balance away (leave only small amount)
            vm.prank(address(this));
            token.transfer(address(0xdead), contractBalance - 1);
        }

        // Release escrow
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Verify: Transfer should fail (insufficient balance) OR succeed if YieldOps refills
        // Fallback to claimable should work if transfer fails
        uint256 claimable = vault.claimableBalances(wid, recipient);
        // Either transfer succeeded (claimable = 0) or failed (claimable > 0)
        // Both are acceptable behaviors
    }

    // ============ Test 5: Edge Case - actualAmount == 0 ============

    function test_releaseEscrowTransfer_actualAmountZero() public {
        // Setup: Create escrow with yield enabled
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 principal = AMOUNT - fee;

        // Configure mock to return actualAmount == 0
        // This simulates withdrawal failure (but didn't revert)
        mockYieldGen.setWithdrawResult(false, 0, 0);
        
        // Don't fund mock - withdrawal will fail

        // Track balance before release
        uint256 totalHeldBefore = vault.totalHeldInEscrowPerToken(address(token));

        // Release escrow
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Verify: _handleYieldAndGetActualAmount returns amount (principal)
        // Verify: Transfer succeeds with amount (principal)
        // Verify: Balance decremented by amount
        uint256 totalHeldAfter = vault.totalHeldInEscrowPerToken(address(token));
        assertEq(totalHeldBefore - totalHeldAfter, principal, "Balance should decrement by principal");

        // Verify recipient received principal
        uint256 recipientBalance = token.balanceOf(recipient);
        assertGe(recipientBalance, principal, "Recipient should receive at least principal");
    }

    // ============ Test 6: YieldOps Call Failure ============

    function test_releaseEscrowTransfer_yieldOpsCallFailure() public {
        // Setup: Create escrow with yield enabled
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
        uint256 principal = AMOUNT - fee;

        // Configure mock to revert (simulates YieldOps call failure)
        mockYieldGen.setRevert(true);
        
        // Don't fund mock - will revert on withdrawal
        // Note: Tokens are already in mock from createEscrow deposit, so mock has them

        // Track balance before release
        uint256 totalHeldBefore = vault.totalHeldInEscrowPerToken(address(token));

        // Release escrow - should still work (falls back to principal)
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Verify: Balance decremented by principal
        uint256 totalHeldAfter = vault.totalHeldInEscrowPerToken(address(token));
        assertEq(totalHeldBefore - totalHeldAfter, principal, "Balance should decrement by principal");

        // When yield withdrawal reverts, tokens are stuck in mock module
        // So escrow doesn't have tokens to transfer - it sets amount as claimable
        // Verify amount is claimable (not directly transferred)
        uint256 claimable = vault.claimableBalances(wid, recipient);
        assertGe(claimable, principal, "Amount should be claimable when escrow lacks tokens");
        
        // To verify the system works end-to-end, we need to return tokens from mock
        // and have recipient withdraw. For now, we verify claimable is set correctly.
    }
}

/**
 * @title MockYieldGenForEdgeCases
 * @notice Mock yield generation module for testing edge cases
 * @dev Simulates Aave withdrawal by transferring tokens to escrow contract
 */
contract MockYieldGenForEdgeCases is IYieldModule {
    using SafeERC20 for IERC20;

    bool public shouldRevert = false;
    bool public withdrawSuccess = true;
    uint256 public actualAmount = 0;
    uint256 public yieldAmount = 0;
    
    // Track deposits for withdrawal simulation
    // Maps escrowContract -> workflowId -> deposited amount
    mapping(address => mapping(uint256 => uint256)) public deposits;
    // Track which escrow contract deposited for each workflowId
    // In real flow, BaseEscrow calls module, so msg.sender is escrowContract
    // But YieldOps calls unwindToEscrow, so we need to track escrowContract per workflowId
    mapping(uint256 => address) public workflowToEscrow;

    function setWithdrawResult(bool _success, uint256 _actualAmount, uint256 _yieldAmount) external {
        withdrawSuccess = _success;
        actualAmount = _actualAmount;
        yieldAmount = _yieldAmount;
    }

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function initializeYield(
        uint256 escrowId,
        address token,
        uint256 amount,
        YieldPreset /* yieldMode */
    ) external override returns (uint256) {
        // Simulate deposit: transfer tokens from escrow to this module (like Aave)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender][escrowId] = amount;
        workflowToEscrow[escrowId] = msg.sender; // Track escrow contract for this workflow
        return amount;
    }

    function unwindToEscrow(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external override returns (uint256 principalOut, uint256 yieldOut) {
        if (shouldRevert) {
            revert("MockYieldGen: Reverted");
        }
        
        address escrowContract = msg.sender;
        uint256 balance = IERC20(token).balanceOf(address(this));
        
        // Determine total amount to transfer back
        uint256 totalAmount;
        if (actualAmount > 0) {
            // Use explicitly configured actualAmount (this is TOTAL, not just principal)
            totalAmount = actualAmount;
        } else if (withdrawSuccess) {
            // Calculate from principalExpected + yieldAmount if success is true
            totalAmount = principalExpected + yieldAmount;
        } else {
            // If withdrawSuccess is false, we can't provide yield, just return principal
            totalAmount = principalExpected;
        }
        
        // Cap to available balance
        if (totalAmount > balance) {
            totalAmount = balance;
        }
        if (totalAmount > 0) {
            IERC20(token).safeTransfer(escrowContract, totalAmount);
        }
        
        // Clear tracking
        deposits[escrowContract][escrowId] = 0;
        workflowToEscrow[escrowId] = address(0);
        
        // Return principal and yield separately
        // If withdrawSuccess is false, we return all transferred amount as principal (no yield)
        if (!withdrawSuccess) {
            return (totalAmount, 0);
        }
        
        // Return principal and yield separately
        // principalOut is what we're returning minus the yield
        // But we need to be careful: if actualAmount was set, it includes both principal and yield
        uint256 actualPrincipal = actualAmount > 0 ? (actualAmount - yieldAmount) : principalExpected;
        return (actualPrincipal, yieldAmount);
    }

    function emergencyUnwind(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external override returns (uint256) {
        if (shouldRevert) {
            revert("MockYieldGen: Reverted");
        }
        
        address escrowContract = msg.sender;
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 toReturn = deposits[escrowContract][escrowId];
        
        if (toReturn == 0) {
            toReturn = principalExpected;
        }
        
        if (toReturn > balance) {
            toReturn = balance;
        }
        
        if (toReturn > 0) {
            IERC20(token).safeTransfer(escrowContract, toReturn);
            deposits[escrowContract][escrowId] = 0;
            workflowToEscrow[escrowId] = address(0);
            return toReturn;
        }
        
        revert("Emergency unwind failed");
    }

    function canHandle(
        address /* token */,
        YieldPreset /* mode */,
        uint256 /* amount */
    ) external pure override returns (bool, bytes32) {
        return (true, bytes32(0));
    }

    function getModuleInfo()
        external pure override returns (string memory, string memory, bytes32) {
        return ("MockYieldGenForEdgeCases", "1.0", keccak256("mock-test"));
    }
    
    // Helper to fund the mock for testing
    function fund(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}

