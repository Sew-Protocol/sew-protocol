// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/mocks/MockFeeOnTransfer.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';

/**
 * @title EscrowEdgeCasesTest
 * @notice Tests for edge cases including Fee-on-Transfer tokens and large amounts
 */
contract EscrowEdgeCasesTest is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    MockFeeOnTransfer public feeToken;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;

    address public owner;
    address public timelock;
    address public feeAddress;
    address public resolver;
    address public buyer;
    address public seller;

    uint256 public constant ESCROW_FEE = 100; // 1%

    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        buyer = address(0x1001);
        seller = address(0x1002);

        resolutionModule = new DefaultResolutionModule(owner, resolver);
        token = new ERC20Mock('Token', 'TKN', owner, 10000000e18);
        // Fee token with 1% fee (100 bps)
        feeToken = new MockFeeOnTransfer('FeeToken', 'FEE', owner, 10000000e18, 100, address(0xdead));
        
        yieldOps = new YieldOps();
        disputeOps = new DisputeOps();
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps));

        // Setup vault
        vault.grantRole(vault.ROLE_TIMELOCK(), owner);
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);

        // Queue and activate resolution module
        vault.queueResolutionModule(address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        vault.activateResolutionModule();
    }

    // ============ Fee-on-Transfer Tests ============

    function test_createEscrow_FeeOnTransfer_Insolvency() public {
        uint256 amount = 1000e18;
        // Mint to buyer
        feeToken.transfer(buyer, amount * 2); // Give extra

        vm.startPrank(buyer);
        feeToken.approve(address(vault), amount);
        
        // Fee is 1% (100 bps) on transfer
        // Vault receives: amount * 0.99
        // Vault expects: amount
        // Vault calculates internal fee: amount * 0.01 (escrow fee)
        // Vault records amountAfterFee: amount * 0.99
        
        // Total held recorded: amount * 0.99 (amountAfterFee) + amount * 0.01 (escrow fee) = amount
        // Actual balance in vault: amount * 0.99 (transfer fee)
        
        // So vault thinks it has 'amount', but it has 'amount * 0.99'
        // This is a deficit of 1%
        
        uint256 escrowId = vault.createEscrow(address(feeToken), seller, amount);
        vm.stopPrank();

        // Verify the deficit
        uint256 actualBalance = feeToken.balanceOf(address(vault));
        uint256 expectedBalance = amount; // The vault thinks it has this
        
        // If the bug exists, actual < expected
        // With 1% transfer fee on 1000, actual should be 990
        assertEq(actualBalance, 990e18); 
        
        // Check what the vault thinks
        uint256 held = vault.totalHeldInEscrowPerToken(address(feeToken));
        uint256 fees = vault.totalFeesPerToken(address(feeToken));
        uint256 totalRecorded = held + fees;
        
        assertEq(totalRecorded, 1000e18);
        
        // This confirms the bug: Recorded (1000) > Actual (990)
        assertGt(totalRecorded, actualBalance);
        
        // Now try to release - should fail due to insufficient balance
        // releaseEscrowTransfer is called by sender (buyer) for release
        
        vm.prank(buyer);
        // Expect revert because vault tries to transfer amountAfterFee (990)
        // But fees (10) are also tracked.
        // Wait, amountAfterFee = 1000 - 10 = 990.
        // Fees = 10.
        // Actual balance = 990.
        // If we release 990, it might work IF fees are not withdrawn yet.
        // But fees are "reserved".
        // totalHeldInEscrowPerToken = 990.
        // totalFeesPerToken = 10.
        
        // release transfers 'amountAfterFee' (990).
        // It succeeds if balance >= 990. Balance IS 990.
        // So release WORKS, but fees are stuck/insolvent.
        
        vault.releaseEscrowTransfer(escrowId);
        
        // Autotransfer may have automatically transferred funds
        // If autotransfer succeeded, withdraw will fail (no claimable balance)
        // If autotransfer failed (fallback), withdraw will succeed
        uint256 claimable = vault.claimable(escrowId, seller, address(feeToken));
        if (claimable > 0) {
            // Fallback occurred, can withdraw
            vm.prank(seller); // Seller is the recipient
            vault.withdrawEscrow(escrowId);
        } else {
            // Autotransfer succeeded, funds already transferred
            // No need to withdraw
        }
        
        // Now withdraw fees
        vm.prank(feeAddress);
        // Withdraw 10 tokens
        // Balance should be 0 (started 990, released 990).
        // Try to withdraw 10.
        vm.expectRevert(); // Should revert due to lack of funds
        vault.withdrawFees(address(feeToken));
    }

    // ============ Large Amount Tests ============

    function test_createEscrow_MaxAmount_Overflow() public {
        // ESCROW_FEE is 100 (1%)
        // Max safe amount is type(uint256).max / 100
        uint256 maxSafeAmount = type(uint256).max / 100;
        
        // Try slightly more - should revert due to multiplication overflow
        uint256 unsafeAmount = maxSafeAmount + 1;
        
        token.mint(buyer, unsafeAmount);
        vm.startPrank(buyer);
        token.approve(address(vault), unsafeAmount);
        
        vm.expectRevert(); // Arithmetic overflow/panic
        vault.createEscrow(address(token), seller, unsafeAmount);
        vm.stopPrank();
    }

    function test_createEscrow_MaxSafeAmount() public {
        uint256 maxSafeAmount = type(uint256).max / 100;
        
        token.mint(buyer, maxSafeAmount);
        vm.startPrank(buyer);
        token.approve(address(vault), maxSafeAmount);
        
        uint256 escrowId = vault.createEscrow(address(token), seller, maxSafeAmount);
        
        uint256 fee = (maxSafeAmount * 100) / 10000;
        uint256 expectedAmountAfterFee = maxSafeAmount - fee;
        
        uint256 deposited = vault.getTotalDeposited(escrowId);
        assertEq(deposited, expectedAmountAfterFee);
        vm.stopPrank();
    }
}
