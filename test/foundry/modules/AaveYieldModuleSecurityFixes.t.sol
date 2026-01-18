// SPDX-License-Identifier: UNLICENSED
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/MockAavePoolReverting.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/modules/AaveYieldGenerationModule.sol';

/**
 * @title AaveYieldModuleSecurityFixesTest
 * @notice Tests for security fixes: HIGH-1 (slippage), HIGH-2 (state clearing), HIGH-3 (batch limits)
 */
contract AaveYieldModuleSecurityFixesTest is Test {
    MockAavePool public pool;
    MockAavePoolReverting public revertingPool;
    ERC20Mock public token;
    MockAToken public aToken;
    MockPoolAddressesProvider public provider;
    AaveYieldGenerationModule public aaveModule;

    address public escrow = address(0xBEEF);
    address public owner = address(this);

    uint256 constant INITIAL_TRANSFER = 1_000_000 ether;
    uint256 constant SLIPPAGE_TOLERANCE_BPS = 10; // 0.1% = 10 basis points

    function setUp() public {
        // Deploy token and pools
        token = new ERC20Mock('Mock Token', 'MOCK', address(this), INITIAL_TRANSFER);
        pool = new MockAavePool();
        revertingPool = new MockAavePoolReverting();

        // Deploy aToken and link to pools
        aToken = new MockAToken(address(token), 'aMock', 'aM');
        aToken.setPool(address(pool));
        pool.setAToken(address(token), address(aToken));
        revertingPool.setAToken(address(token), address(aToken));

        // Deploy provider
        provider = new MockPoolAddressesProvider(address(pool));

        // Deploy module
        aaveModule = new AaveYieldGenerationModule(owner);
        bytes32 ROLE_TIMELOCK = aaveModule.ROLE_TIMELOCK();
        aaveModule.grantRole(ROLE_TIMELOCK, owner);

        // Queue provider and activate
        aaveModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        aaveModule.activateAavePoolProvider();

        // Enable Aave
        aaveModule.setAaveEnabled(true);

        // Register token for Aave
        aaveModule.registerTokenForAave(address(token), address(aToken));

        // Fund escrow address with tokens
        token.mint(escrow, INITIAL_TRANSFER);
    }

    // ============ HIGH-1: Slippage Protection Tests ============

    /**
     * @notice Test HIGH-1 fix: Slippage protection with exact threshold
     */
    function test_SlippageProtection_ExactThreshold() public {
        uint256 workflowId = 1;
        uint256 deposit = 10 ether;

        // Setup reverting pool with slippage at threshold
        MockPoolAddressesProvider slippageProvider = new MockPoolAddressesProvider(
            address(revertingPool)
        );
        aaveModule.queueAavePoolProvider(address(slippageProvider));
        vm.warp(block.timestamp + 7 days + 1);
        aaveModule.activateAavePoolProvider();

        // Update aToken's pool address to reverting pool (needed for mint/burn)
        aToken.setPool(address(revertingPool));

        // Deposit
        vm.prank(escrow);
        token.approve(address(revertingPool), deposit);
        vm.prank(escrow);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Set slippage exactly at threshold (10 bps = 0.1%)
        revertingPool.setSlippageBps(SLIPPAGE_TOLERANCE_BPS);
        token.mint(address(revertingPool), 1000 ether);

        // Withdraw should succeed (at threshold, should pass)
        vm.prank(escrow);
        (bool success, uint256 actualAmount, ) = aaveModule.withdrawWithYield(
            workflowId,
            address(token),
            deposit
        );

        assertTrue(success, 'Withdrawal should succeed at threshold');
        uint256 minimumAmount = deposit * (10000 - SLIPPAGE_TOLERANCE_BPS) / 10000;
        assertGe(actualAmount, minimumAmount, 'Actual amount should meet minimum');
    }

    /**
     * @notice Test HIGH-1 fix: Slippage protection exceeds threshold emits event
     */
    function test_SlippageProtection_ExceedsThreshold() public {
        uint256 workflowId = 2;
        uint256 deposit = 10 ether;

        // Setup reverting pool with high slippage
        MockPoolAddressesProvider slippageProvider = new MockPoolAddressesProvider(
            address(revertingPool)
        );
        aaveModule.queueAavePoolProvider(address(slippageProvider));
        vm.warp(block.timestamp + 7 days + 1);
        aaveModule.activateAavePoolProvider();

        // Update aToken's pool address to reverting pool (needed for mint/burn)
        aToken.setPool(address(revertingPool));

        // Deposit
        vm.prank(escrow);
        token.approve(address(revertingPool), deposit);
        vm.prank(escrow);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Set high slippage (20 bps = 0.2%, exceeds 10 bps tolerance)
        revertingPool.setSlippageBps(20);
        token.mint(address(revertingPool), 1000 ether);

        // Withdraw should succeed but emit event
        vm.prank(escrow);
        vm.expectEmit(true, true, false, false);
        emit AaveYieldGenerationModule.AaveWithdrawalFailedEvent(workflowId, address(token));
        (bool success, , ) = aaveModule.withdrawWithYield(workflowId, address(token), deposit);

        assertTrue(success, 'Withdrawal should succeed even with high slippage');
    }

    /**
     * @notice Test HIGH-1 fix: No slippage scenario
     */
    function test_SlippageProtection_NoSlippage() public {
        uint256 workflowId = 3;
        uint256 deposit = 10 ether;

        // Deposit
        vm.prank(escrow);
        token.approve(address(pool), deposit);
        vm.prank(escrow);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Simulate yield (no slippage)
        pool.simulateYield(address(token), 10);
        token.mint(address(pool), 1000 ether);

        // Withdraw should succeed without event
        vm.prank(escrow);
        (bool success, uint256 actualAmount, ) = aaveModule.withdrawWithYield(
            workflowId,
            address(token),
            deposit
        );

        assertTrue(success, 'Withdrawal should succeed');
        assertGe(actualAmount, deposit, 'Actual amount should be >= deposit (with yield)');
    }

    // ============ HIGH-2: State Clearing Order Tests ============

    /**
     * @notice Test HIGH-2 fix: Withdrawal failure preserves state
     */
    function test_StateClearingOrder_WithdrawalFails() public {
        uint256 workflowId = 4;
        uint256 deposit = 10 ether;

        // Setup reverting pool
        MockPoolAddressesProvider revertingProvider = new MockPoolAddressesProvider(
            address(revertingPool)
        );
        aaveModule.queueAavePoolProvider(address(revertingProvider));
        vm.warp(block.timestamp + 7 days + 1);
        aaveModule.activateAavePoolProvider();

        // Update aToken's pool address to reverting pool (needed for mint/burn)
        aToken.setPool(address(revertingPool));

        // Deposit
        vm.prank(escrow);
        token.approve(address(revertingPool), deposit);
        vm.prank(escrow);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Configure pool to revert withdrawals
        revertingPool.setShouldRevertWithdraw(true);
        token.mint(address(revertingPool), 1000 ether);

        // Record state before withdrawal attempt
        (bool inAaveBefore, uint256 aTokenBalBefore, uint256 origDepBefore) = aaveModule
            .getEscrowAaveData(escrow, workflowId);

        assertTrue(inAaveBefore, 'Should be in Aave before withdrawal');
        assertGt(aTokenBalBefore, 0, 'Should have aToken balance');
        assertGt(origDepBefore, 0, 'Should have original deposit');

        // Attempt withdrawal (will fail)
        vm.prank(escrow);
        (bool success, , ) = aaveModule.withdrawWithYield(workflowId, address(token), deposit);

        assertFalse(success, 'Withdrawal should fail');

        // HIGH-2 FIX: State preserved after failure
        (bool inAaveAfter, uint256 aTokenBalAfter, uint256 origDepAfter) = aaveModule.getEscrowAaveData(
            escrow,
            workflowId
        );

        assertEq(inAaveAfter, inAaveBefore, 'escrowInAave should be preserved');
        assertEq(aTokenBalAfter, aTokenBalBefore, 'aTokenBalance should be preserved');
        assertEq(origDepAfter, origDepBefore, 'originalDeposit should be preserved');
    }

    /**
     * @notice Test HIGH-2 fix: Withdrawal success clears state after withdrawal
     */
    function test_StateClearingOrder_WithdrawalSucceeds() public {
        uint256 workflowId = 5;
        uint256 deposit = 10 ether;

        // Deposit
        vm.prank(escrow);
        token.approve(address(pool), deposit);
        vm.prank(escrow);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Simulate yield and ensure pool has tokens
        pool.simulateYield(address(token), 10);
        token.mint(address(pool), 1000 ether);

        // Withdraw
        vm.prank(escrow);
        (bool success, , ) = aaveModule.withdrawWithYield(workflowId, address(token), deposit);

        assertTrue(success, 'Withdrawal should succeed');

        // HIGH-2 FIX: State cleared AFTER successful withdrawal
        (bool inAaveAfter, uint256 aTokenBalAfter, uint256 origDepAfter) = aaveModule.getEscrowAaveData(
            escrow,
            workflowId
        );

        assertFalse(inAaveAfter, 'escrowInAave should be false');
        assertEq(aTokenBalAfter, 0, 'aTokenBalance should be 0');
        assertEq(origDepAfter, 0, 'originalDeposit should be 0');
    }

    /**
     * @notice Test HIGH-2 fix: Multiple withdrawal attempts after failure
     */
    function test_StateClearingOrder_MultipleAttemptsAfterFailure() public {
        uint256 workflowId = 6;
        uint256 deposit = 10 ether;

        // Setup reverting pool
        MockPoolAddressesProvider revertingProvider = new MockPoolAddressesProvider(
            address(revertingPool)
        );
        aaveModule.queueAavePoolProvider(address(revertingProvider));
        vm.warp(block.timestamp + 7 days + 1);
        aaveModule.activateAavePoolProvider();

        // Update aToken's pool address to reverting pool (needed for mint/burn)
        aToken.setPool(address(revertingPool));

        // Deposit
        vm.prank(escrow);
        token.approve(address(revertingPool), deposit);
        vm.prank(escrow);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        revertingPool.setShouldRevertWithdraw(true);
        token.mint(address(revertingPool), 1000 ether);

        // First withdrawal attempt (fails)
        vm.prank(escrow);
        (bool success1, , ) = aaveModule.withdrawWithYield(workflowId, address(token), deposit);
        assertFalse(success1, 'First withdrawal should fail');

        // State should still be preserved
        (bool inAave1, , ) = aaveModule.getEscrowAaveData(escrow, workflowId);
        assertTrue(inAave1, 'State should be preserved after first failure');

        // Second withdrawal attempt (still fails)
        vm.prank(escrow);
        (bool success2, , ) = aaveModule.withdrawWithYield(workflowId, address(token), deposit);
        assertFalse(success2, 'Second withdrawal should fail');

        // State should still be preserved
        (bool inAave2, , ) = aaveModule.getEscrowAaveData(escrow, workflowId);
        assertTrue(inAave2, 'State should be preserved after second failure');

        // Fix pool and withdraw successfully
        revertingPool.setShouldRevertWithdraw(false);
        vm.prank(escrow);
        (bool success3, , ) = aaveModule.withdrawWithYield(workflowId, address(token), deposit);
        assertTrue(success3, 'Third withdrawal should succeed');

        // State should now be cleared
        (bool inAave3, , ) = aaveModule.getEscrowAaveData(escrow, workflowId);
        assertFalse(inAave3, 'State should be cleared after successful withdrawal');
    }

    // ============ HIGH-3: Batch Size Limits Tests ============

    /**
     * @notice Test HIGH-3 fix: Batch size at maximum allowed
     */
    function test_BatchSizeLimit_MaxAllowed() public {
        uint256 maxBatchSize = aaveModule.MAX_BATCH_SIZE();
        assertEq(maxBatchSize, 50, 'MAX_BATCH_SIZE should be 50');

        // Create arrays at maximum size
        address[] memory tokens = new address[](maxBatchSize);
        address[] memory aTokens = new address[](maxBatchSize);

        // Deploy tokens
        for (uint256 i = 0; i < maxBatchSize; i++) {
            ERC20Mock newToken = new ERC20Mock(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i)),
                address(this),
                INITIAL_TRANSFER
            );
            MockAToken newAToken = new MockAToken(
                address(newToken),
                string(abi.encodePacked('aToken', i)),
                string(abi.encodePacked('aTK', i))
            );
            newAToken.setPool(address(pool));
            pool.setAToken(address(newToken), address(newAToken));

            tokens[i] = address(newToken);
            aTokens[i] = address(newAToken);
        }

        // Should succeed at maximum
        aaveModule.batchRegisterTokensForAave(tokens, aTokens);

        // Verify all tokens registered
        for (uint256 i = 0; i < maxBatchSize; i++) {
            assertTrue(
                aaveModule.isTokenSupportedByAave(tokens[i]),
                'Token should be registered'
            );
        }
    }

    /**
     * @notice Test HIGH-3 fix: Batch size exceeds maximum reverts
     */
    function test_BatchSizeLimit_ExceedsMax() public {
        uint256 maxBatchSize = aaveModule.MAX_BATCH_SIZE();
        uint256 exceedSize = maxBatchSize + 1;

        // Create arrays exceeding maximum
        address[] memory tokens = new address[](exceedSize);
        address[] memory aTokens = new address[](exceedSize);

        // Deploy tokens
        for (uint256 i = 0; i < exceedSize; i++) {
            ERC20Mock newToken = new ERC20Mock(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i)),
                address(this),
                INITIAL_TRANSFER
            );
            MockAToken newAToken = new MockAToken(
                address(newToken),
                string(abi.encodePacked('aToken', i)),
                string(abi.encodePacked('aTK', i))
            );
            newAToken.setPool(address(pool));
            pool.setAToken(address(newToken), address(newAToken));

            tokens[i] = address(newToken);
            aTokens[i] = address(newAToken);
        }

        // Should revert when exceeding maximum
        vm.expectRevert(abi.encodeWithSignature("BatchSizeTooLarge(uint256,uint256)", tokens.length, 50));
        aaveModule.batchRegisterTokensForAave(tokens, aTokens);
    }

    /**
     * @notice Test HIGH-3 fix: Batch size one below maximum succeeds
     */
    function test_BatchSizeLimit_OneBelowMax() public {
        uint256 maxBatchSize = aaveModule.MAX_BATCH_SIZE();
        uint256 belowSize = maxBatchSize - 1;

        // Create arrays one below maximum
        address[] memory tokens = new address[](belowSize);
        address[] memory aTokens = new address[](belowSize);

        // Deploy tokens
        for (uint256 i = 0; i < belowSize; i++) {
            ERC20Mock newToken = new ERC20Mock(
                string(abi.encodePacked('Token', i)),
                string(abi.encodePacked('TK', i)),
                address(this),
                INITIAL_TRANSFER
            );
            MockAToken newAToken = new MockAToken(
                address(newToken),
                string(abi.encodePacked('aToken', i)),
                string(abi.encodePacked('aTK', i))
            );
            newAToken.setPool(address(pool));
            pool.setAToken(address(newToken), address(newAToken));

            tokens[i] = address(newToken);
            aTokens[i] = address(newAToken);
        }

        // Should succeed
        aaveModule.batchRegisterTokensForAave(tokens, aTokens);

        // Verify tokens registered
        for (uint256 i = 0; i < belowSize; i++) {
            assertTrue(
                aaveModule.isTokenSupportedByAave(tokens[i]),
                'Token should be registered'
            );
        }
    }

    /**
     * @notice Test HIGH-3 fix: Empty batch succeeds
     */
    function test_BatchSizeLimit_EmptyBatch() public {
        address[] memory tokens = new address[](0);
        address[] memory aTokens = new address[](0);

        // Should succeed with empty batch
        aaveModule.batchRegisterTokensForAave(tokens, aTokens);
    }
}
