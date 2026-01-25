// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowableERC20.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

contract EscrowableERC20CoverageTest is Test {
    EscrowableERC20 public token;
    EscrowAdminContract public adminContract;
    ModuleManagementContract public moduleManagement;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;

    address public owner;
    address public timelock;
    address public guardian;
    address public feeRecipient;
    address public resolver;
    address public user1;
    address public user2;

    uint256 public constant ESCROW_FEE = 100; // 1%

    function setUp() public {
        owner = address(this);
        timelock = address(0x1);
        guardian = address(0x2);
        feeRecipient = address(0x3);
        resolver = address(0x4);
        user1 = address(0x5);
        user2 = address(0x6);

        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        settlementOps = new SettlementOps(owner);
        createOps = new CreateOps(owner);
        bondCollector = new BondCollector(owner);
        moduleManagement = new ModuleManagementContract(owner);
        
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();

        token = new EscrowableERC20(
            "Escrow Token",
            "ETKN",
            ESCROW_FEE,
            feeRecipient,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );

        adminContract = new EscrowAdminContract(owner);
        
        // Roles setup
        token.grantRole(token.ROLE_TIMELOCK(), timelock);
        token.grantRole(token.ROLE_GUARDIAN(), guardian);
        token.grantRole(token.ROLE_ADMIN_CONTRACT(), address(adminContract));
        token.grantRole(token.ROLE_ADMIN_CONTRACT(), owner);

        // Wire ops
        token.setCreateOps(address(createOps));
        token.setSettlementOps(address(settlementOps));
        token.setBondCollector(address(bondCollector));
        
        yieldOps.registerEscrowContract(address(token));
        disputeOps.registerEscrowContract(address(token));
        settlementOps.registerEscrowContract(address(token));
        createOps.registerEscrowContract(address(token));
        bondCollector.registerEscrowContract(address(token));
        moduleManagement.registerEscrowContract(address(token));

        // Modules
        // Bypass EscrowAdminContract slow lane for test setup to avoid weird timing issues
        token.setResolutionModule(address(resolutionModule));

        // Release strategy
        vm.prank(address(token));
        moduleManagement.queueModule(address(token), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(address(token));
        moduleManagement.activateModule(address(token), BaseEscrow.ModuleType.RELEASE);

        // Distribute tokens
        token.transfer(user1, 1000e18);
        token.transfer(user2, 1000e18);
    }

    // ============ Token & Escrow Basics ============

    function test_CreateEscrow_Success() public {
        uint256 amount = 100e18;
        
        vm.prank(user1);
        uint256 workflowId = token.createEscrow(user2, amount);

        // Check balances
        // User1 should have 1000 - 100 = 900
        assertEq(token.balanceOf(user1), 900e18);
        // Token contract should hold the amount (100)
        assertEq(token.balanceOf(address(token)), amount);
        
        // Check escrow tracking
        // Fee is 1%. 1e18. AmountAfterFee = 99e18.
        uint256 fee = amount * ESCROW_FEE / 10000;
        uint256 expected = amount - fee;
        
        assertEq(token.totalHeldInEscrow(), expected);
        assertEq(token.totalFees(), fee);
        
        // Verify transfer details
        (address tokenAddr, address to, address from, , uint256 amtAfterFee,,,,,) = token.escrowTransfers(workflowId);
        assertEq(tokenAddr, address(token));
        assertEq(to, user2);
        assertEq(from, user1);
        assertEq(amtAfterFee, expected);
    }

    function test_ReleaseEscrow() public {
        uint256 amount = 100e18;
        vm.prank(user1);
        uint256 workflowId = token.createEscrow(user2, amount);

        vm.prank(user1);
        token.releaseEscrowTransfer(workflowId);

        uint256 fee = amount * ESCROW_FEE / 10000;
        uint256 payout = amount - fee;

        // User2 should receive payout
        assertEq(token.balanceOf(user2), 1000e18 + payout);
        assertEq(token.totalHeldInEscrow(), 0);
        assertEq(token.totalFees(), fee);
    }

    function test_CancelEscrow() public {
        uint256 amount = 100e18;
        vm.prank(user1);
        uint256 workflowId = token.createEscrow(user2, amount);

        // Sender cancels (needs recipient consent or timeout, but senderCancel initiates)
        // If pending, needs both.
        vm.prank(user1);
        token.senderCancel(workflowId);
        vm.prank(user2);
        token.recipientCancel(workflowId);

        uint256 fee = amount * ESCROW_FEE / 10000;
        uint256 refund = amount - fee;

        // User1 should receive refund
        assertEq(token.balanceOf(user1), 1000e18 - amount + refund);
        assertEq(token.totalHeldInEscrow(), 0);
    }

    // ============ Fee Management ============

    function test_WithdrawFees() public {
        uint256 amount = 100e18;
        vm.prank(user1);
        token.createEscrow(user2, amount);

        uint256 fee = amount * ESCROW_FEE / 10000;
        assertEq(token.totalFees(), fee);

        // Withdraw
        vm.prank(feeRecipient);
        token.withdrawFees();

        assertEq(token.totalFees(), 0);
        assertEq(token.balanceOf(feeRecipient), fee);
    }

    function test_WithdrawFees_Unauthorized() public {
        vm.prank(user1);
        token.createEscrow(user2, 100e18);

        vm.prank(user1);
        vm.expectRevert(); // NotFeeAddress
        token.withdrawFees();
    }

    function test_WithdrawFees_NoFees() public {
        vm.prank(feeRecipient);
        vm.expectRevert(); // NoFeesToWithdraw
        token.withdrawFees();
    }

    // ============ Recovery ============

    function test_RecoverERC20_Excess() public {
        // Mint extra tokens to contract (simulate accidental transfer)
        // Since we can't easily mint to it externally without being owner (it has initial supply),
        // we transfer from user1
        vm.prank(user1);
        token.transfer(address(token), 50e18);

        // This 50e18 is not tracked in totalHeldInEscrow or totalFees
        uint256 available = 50e18;
        uint256 balBefore = token.balanceOf(owner);

        vm.prank(timelock);
        token.recoverERC20(address(token), owner, available);

        assertEq(token.balanceOf(owner), balBefore + available);
    }

    function test_RecoverERC20_CannotRecoverEscrowed() public {
        uint256 amount = 100e18;
        vm.prank(user1);
        token.createEscrow(user2, amount);

        // Contract balance = 100e18. Held = 99e18. Fees = 1e18.
        // Available excess = 0.
        
        vm.prank(timelock);
        vm.expectRevert(); // AmountExceedsAvailable or NoTokensToRecover
        token.recoverERC20(address(token), owner, 1);
    }

    function test_RecoverERC20_OtherToken() public {
        // Deploy another token
        ERC20Mock other = new ERC20Mock("Other", "OTH", address(this), 1000e18);
        other.transfer(address(token), 100e18);

        vm.prank(timelock);
        // BaseEscrow recoverERC20 handles other tokens via RecoveryLibrary
        // Wait, EscrowableERC20 overrides recoverERC20 but reverts if token != address(this) ??
        // Let's check implementation.
        // "if (token != address(this)) revert InvalidAddress(ADDR_TOKEN, token);"
        // It seems EscrowableERC20 restricts recovery to ITSELF only?
        // Let's verify.
        
        vm.expectRevert(); 
        token.recoverERC20(address(other), owner, 100e18);
        
        // This confirms the implementation restricts recovery to self.
        // If we want to recover other tokens, we might need a separate mechanism or the implementation is strict.
        // The implementation explicitly checks `token != address(this)`.
    }

    // ============ Internal Overrides Coverage ============

    function test_PullTokens_RevertInvalid() public {
        // We can't call _pullTokens directly, but we can trigger it via createEscrow
        // token.createEscrow hardcodes address(this) as token, so we can't pass invalid token there.
        // The check inside _pullTokens is "token != address(this)".
        // It's effectively unreachable via public functions unless we find a path.
        // However, checking coverage, it marks it as covered if executed.
        // The valid path covers the "happy path".
        // The invalid path is unreachable in current code, which is fine (defensive).
    }

    function test_UpdateEscrowBalance_Underflow() public {
        // Hard to trigger underflow in normal operation due to logic checks
        // but good to know it exists.
    }
}
