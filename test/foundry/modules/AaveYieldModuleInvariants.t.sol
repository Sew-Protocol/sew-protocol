// SPDX-License-Identifier: UNLICENSED
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/MockAavePoolReverting.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/modules/AaveYieldGenerationModule.sol';

/**
 * @title AaveYieldModuleInvariantsTest
 * @notice Comprehensive invariant tests for AaveYieldGenerationModule
 * @dev Tests critical properties:
 *      1. State consistency (tracking data matches escrowInAave)
 *      2. Total deposited accuracy (sum of deposits equals totalDepositedToAave)
 *      3. Yield calculation bounded (calculated yield <= actual yield)
 *      4. Slippage protection (withdrawal amount >= minimum expected)
 *      5. Checks-effects-interactions pattern (state cleared after successful withdrawal)
 */
contract AaveYieldModuleInvariantsTest is Test {
    MockAavePool public pool;
    MockAavePoolReverting public revertingPool;
    ERC20Mock public token;
    MockAToken public aToken;
    MockPoolAddressesProvider public provider;
    AaveYieldGenerationModule public aaveModule;

    address public escrow1 = address(0xBEEF1);
    address public escrow2 = address(0xBEEF2);
    address public owner = address(this);

    uint256 constant INITIAL_TRANSFER = 1_000_000 ether;
    uint256 constant SLIPPAGE_TOLERANCE_BPS = 10; // 0.1% = 10 basis points

    struct EscrowData {
        uint256 workflowId;
        uint256 deposit;
        bool inAave;
        uint256 aTokenBalance;
        uint256 originalDeposit;
    }

    EscrowData[] public escrows;

    function setUp() public {
        // Deploy token and pool
        token = new ERC20Mock('Mock Token', 'MOCK', address(this), INITIAL_TRANSFER);
        pool = new MockAavePool();
        revertingPool = new MockAavePoolReverting();

        // Deploy aToken and link to pool
        aToken = new MockAToken(address(token), 'aMock', 'aM');
        aToken.setPool(address(pool));
        pool.setAToken(address(token), address(aToken));
        revertingPool.setAToken(address(token), address(aToken));

        // Deploy provider
        provider = new MockPoolAddressesProvider(address(pool));

        // Deploy module with this test as admin
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

        // Fund escrow addresses with tokens
        token.mint(escrow1, INITIAL_TRANSFER);
        token.mint(escrow2, INITIAL_TRANSFER);
    }

    // ============ Invariant 1: State Consistency ============

    /**
     * @notice CRITICAL INVARIANT: escrowInAave[contract][workflowId] == true IFF tracking data exists
     */
    function test_StateConsistency_IfInAaveThenTrackingExists() public {
        uint256 workflowId = 1;
        uint256 deposit = 10 ether;

        // Approve and deposit
        vm.prank(escrow1);
        token.approve(address(pool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // INVARIANT: If escrowInAave is true, then tracking data must exist
        (bool inAave, uint256 aTokenBal, uint256 origDep) = aaveModule.getEscrowAaveData(
            escrow1,
            workflowId
        );
        assertTrue(inAave, 'Should be in Aave after deposit');
        assertGt(aTokenBal, 0, 'aTokenBalance should be > 0');
        assertGt(origDep, 0, 'originalDeposit should be > 0');
    }

    /**
     * @notice CRITICAL INVARIANT: If escrowInAave is false, all tracking data should be 0
     */
    function test_StateConsistency_IfNotInAaveThenNoTracking() public {
        uint256 workflowId = 2;

        // Check non-existent escrow
        (bool inAave, uint256 aTokenBal, uint256 origDep) = aaveModule.getEscrowAaveData(
            escrow1,
            workflowId
        );

        // INVARIANT: If not in Aave, all tracking should be zero
        assertFalse(inAave, 'Should not be in Aave');
        assertEq(aTokenBal, 0, 'aTokenBalance should be 0');
        assertEq(origDep, 0, 'originalDeposit should be 0');
    }

    /**
     * @notice CRITICAL INVARIANT: State cleared only after successful withdrawal (HIGH-2 fix)
     */
    function test_StateConsistency_WithdrawalFailurePreservesState() public {
        uint256 workflowId = 3;
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

        // Approve and deposit
        vm.prank(escrow1);
        token.approve(address(revertingPool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Configure pool to revert withdrawals
        revertingPool.setShouldRevertWithdraw(true);
        token.mint(address(revertingPool), 1000 ether); // Ensure pool has tokens

        // Record state before withdrawal attempt
        (bool inAaveBefore, uint256 aTokenBalBefore, uint256 origDepBefore) = aaveModule
            .getEscrowAaveData(escrow1, workflowId);

        // Attempt withdrawal (will fail)
        vm.prank(escrow1);
        (bool success, , ) = aaveModule.withdrawWithYield(workflowId, address(token), deposit);

        assertFalse(success, 'Withdrawal should fail');

        // INVARIANT: State preserved after withdrawal failure (HIGH-2 fix)
        (bool inAaveAfter, uint256 aTokenBalAfter, uint256 origDepAfter) = aaveModule.getEscrowAaveData(
            escrow1,
            workflowId
        );

        assertEq(inAaveAfter, inAaveBefore, 'escrowInAave should be preserved');
        assertEq(aTokenBalAfter, aTokenBalBefore, 'aTokenBalance should be preserved');
        assertEq(origDepAfter, origDepBefore, 'originalDeposit should be preserved');
    }

    /**
     * @notice INVARIANT: State cleared after successful withdrawal
     */
    function test_StateConsistency_WithdrawalSuccessClearsState() public {
        uint256 workflowId = 4;
        uint256 deposit = 10 ether;

        // Approve and deposit
        vm.prank(escrow1);
        token.approve(address(pool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Simulate yield and ensure pool has tokens
        pool.simulateYield(address(token), 10);
        token.mint(address(pool), 1000 ether);

        // Withdraw
        vm.prank(escrow1);
        (bool success, , ) = aaveModule.withdrawWithYield(workflowId, address(token), deposit);
        assertTrue(success, 'Withdrawal should succeed');

        // INVARIANT: State cleared after successful withdrawal
        (bool inAaveAfter, uint256 aTokenBalAfter, uint256 origDepAfter) = aaveModule.getEscrowAaveData(
            escrow1,
            workflowId
        );

        assertFalse(inAaveAfter, 'escrowInAave should be false');
        assertEq(aTokenBalAfter, 0, 'aTokenBalance should be 0');
        assertEq(origDepAfter, 0, 'originalDeposit should be 0');
    }

    // ============ Invariant 2: Total Deposited Tracking ============

    /**
     * @notice CRITICAL INVARIANT: totalDepositedToAave[token] == sum of all original deposits
     */
    function test_TotalDepositedAccuracy_SingleDeposit() public {
        uint256 workflowId = 5;
        uint256 deposit = 10 ether;

        uint256 totalBefore = aaveModule.getTotalDepositedToAave(address(token));

        // Approve and deposit
        vm.prank(escrow1);
        token.approve(address(pool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        uint256 totalAfter = aaveModule.getTotalDepositedToAave(address(token));

        // INVARIANT: Total increased by deposit amount
        assertEq(totalAfter - totalBefore, deposit, 'Total should increase by deposit amount');
    }

    /**
     * @notice INVARIANT: Total deposited decreases on withdrawal
     */
    function test_TotalDepositedAccuracy_WithdrawalDecreasesTotal() public {
        uint256 workflowId = 6;
        uint256 deposit = 10 ether;

        // Deposit
        vm.prank(escrow1);
        token.approve(address(pool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        uint256 totalBefore = aaveModule.getTotalDepositedToAave(address(token));

        // Simulate yield and withdraw
        pool.simulateYield(address(token), 10);
        token.mint(address(pool), 1000 ether);
        vm.prank(escrow1);
        aaveModule.withdrawWithYield(workflowId, address(token), deposit);

        uint256 totalAfter = aaveModule.getTotalDepositedToAave(address(token));

        // INVARIANT: Total decreased by original deposit (not actual amount with yield)
        assertEq(totalBefore - totalAfter, deposit, 'Total should decrease by original deposit');
    }

    /**
     * @notice INVARIANT: Multiple deposits sum correctly
     */
    function test_TotalDepositedAccuracy_MultipleDeposits() public {
        uint256 deposit1 = 10 ether;
        uint256 deposit2 = 20 ether;

        uint256 totalBefore = aaveModule.getTotalDepositedToAave(address(token));

        // Deposit from escrow1
        vm.prank(escrow1);
        token.approve(address(pool), deposit1);
        vm.prank(escrow1);
        aaveModule.depositForYield(1, address(token), deposit1);

        // Deposit from escrow2
        vm.prank(escrow2);
        token.approve(address(pool), deposit2);
        vm.prank(escrow2);
        aaveModule.depositForYield(2, address(token), deposit2);

        uint256 totalAfter = aaveModule.getTotalDepositedToAave(address(token));

        // INVARIANT: Total equals sum of deposits
        assertEq(totalAfter - totalBefore, deposit1 + deposit2, 'Total should equal sum of deposits');
    }

    // ============ Invariant 3: Yield Calculation Bounded ============

    /**
     * @notice INVARIANT: calculateYield() <= actualWithdrawnAmount - originalDeposit
     */
    function test_YieldCalculationBounded_CalculatedYieldNeverExceedsActual() public {
        uint256 workflowId = 7;
        uint256 deposit = 10 ether;

        // Deposit
        vm.prank(escrow1);
        token.approve(address(pool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Simulate yield
        pool.simulateYield(address(token), 100);
        token.mint(address(pool), 1000 ether);

        // Calculate yield (view function)
        vm.prank(escrow1);
        uint256 calculatedYield = aaveModule.calculateYield(workflowId, address(token));

        // Withdraw and get actual yield
        vm.prank(escrow1);
        (, uint256 actualAmount, uint256 actualYield) = aaveModule.withdrawWithYield(
            workflowId,
            address(token),
            deposit
        );

        // INVARIANT: Calculated yield should not exceed actual yield
        // Note: Calculated yield may be slightly less due to timing/precision, but should never exceed
        assertLe(
            calculatedYield,
            actualYield + 1, // Allow 1 wei tolerance for rounding
            'Calculated yield should not exceed actual yield'
        );
    }

    /**
     * @notice INVARIANT: calculateYield() >= 0
     */
    function test_YieldCalculationBounded_AlwaysNonNegative() public {
        uint256 workflowId = 8;
        uint256 deposit = 10 ether;

        // Deposit
        vm.prank(escrow1);
        token.approve(address(pool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Calculate yield (should be >= 0 even with no yield)
        vm.prank(escrow1);
        uint256 calculatedYield = aaveModule.calculateYield(workflowId, address(token));

        // INVARIANT: Yield is always non-negative
        assertGe(calculatedYield, 0, 'Yield should be non-negative');
    }

    // ============ Invariant 4: Slippage Protection ============

    /**
     * @notice CRITICAL INVARIANT: actualAmount >= originalDeposit * 0.999 (within tolerance) - HIGH-1 fix
     */
    function test_SlippageProtection_WithinTolerance() public {
        uint256 workflowId = 9;
        uint256 deposit = 10 ether;

        // Setup reverting pool with slippage
        MockPoolAddressesProvider slippageProvider = new MockPoolAddressesProvider(
            address(revertingPool)
        );
        aaveModule.queueAavePoolProvider(address(slippageProvider));
        vm.warp(block.timestamp + 7 days + 1);
        aaveModule.activateAavePoolProvider();

        // Update aToken's pool address to reverting pool (needed for mint/burn)
        aToken.setPool(address(revertingPool));

        // Deposit
        vm.prank(escrow1);
        token.approve(address(revertingPool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Set small slippage (5 bps = 0.05%, well within 10 bps tolerance)
        revertingPool.setSlippageBps(5);
        token.mint(address(revertingPool), 1000 ether);

        // Withdraw
        vm.prank(escrow1);
        (, uint256 actualAmount, ) = aaveModule.withdrawWithYield(
            workflowId,
            address(token),
            deposit
        );

        // INVARIANT: actualAmount >= minimumAmount (within tolerance)
        uint256 minimumAmount = deposit * (10000 - SLIPPAGE_TOLERANCE_BPS) / 10000;
        assertGe(actualAmount, minimumAmount, 'Actual amount should meet minimum (within tolerance)');
    }

    /**
     * @notice INVARIANT: Slippage event emitted when threshold exceeded - HIGH-1 fix
     */
    function test_SlippageProtection_ExceedsThresholdEmitsEvent() public {
        uint256 workflowId = 10;
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
        vm.prank(escrow1);
        token.approve(address(revertingPool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(workflowId, address(token), deposit);

        // Set high slippage (20 bps = 0.2%, exceeds 10 bps tolerance)
        revertingPool.setSlippageBps(20);
        token.mint(address(revertingPool), 1000 ether);

        // Withdraw and expect event
        vm.prank(escrow1);
        vm.expectEmit(true, true, false, false);
        emit AaveYieldGenerationModule.AaveWithdrawalFailedEvent(workflowId, address(token));
        aaveModule.withdrawWithYield(workflowId, address(token), deposit);
    }

    // ============ Invariant 5: Exposure Tracking ============

    /**
     * @notice INVARIANT: currentExposure never exceeds caps
     */
    function test_ExposureTracking_NeverExceedsCaps() public {
        uint256 cap = 100 ether;
        uint256 deposit = 50 ether;

        // Set cap
        aaveModule.setTokenCap(address(token), cap);

        // Deposit within cap
        vm.prank(escrow1);
        token.approve(address(pool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(1, address(token), deposit);

        uint256 exposure = aaveModule.currentExposure(address(token));

        // INVARIANT: Exposure <= cap
        assertLe(exposure, cap, 'Exposure should not exceed cap');
    }

    /**
     * @notice INVARIANT: Cannot deposit if would exceed cap
     */
    function test_ExposureTracking_CannotExceedCap() public {
        uint256 cap = 100 ether;
        uint256 deposit1 = 60 ether;
        uint256 deposit2 = 50 ether; // Would exceed cap

        // Set cap
        aaveModule.setTokenCap(address(token), cap);

        // First deposit
        vm.prank(escrow1);
        token.approve(address(pool), deposit1);
        vm.prank(escrow1);
        aaveModule.depositForYield(1, address(token), deposit1);

        // Second deposit should fail (would exceed cap)
        vm.prank(escrow2);
        token.approve(address(pool), deposit2);
        vm.prank(escrow2);
        vm.expectRevert(
            abi.encodeWithSelector(
                CapExceeded.selector,
                address(token),
                deposit1 + deposit2,
                cap
            )
        );
        aaveModule.depositForYield(2, address(token), deposit2);
    }

    /**
     * @notice INVARIANT: Exposure reduced on withdrawal
     */
    function test_ExposureTracking_ReducedOnWithdrawal() public {
        uint256 deposit = 50 ether;

        // Deposit
        vm.prank(escrow1);
        token.approve(address(pool), deposit);
        vm.prank(escrow1);
        aaveModule.depositForYield(1, address(token), deposit);

        uint256 exposureBefore = aaveModule.currentExposure(address(token));

        // Withdraw
        pool.simulateYield(address(token), 10);
        token.mint(address(pool), 1000 ether);
        vm.prank(escrow1);
        aaveModule.withdrawWithYield(1, address(token), deposit);

        uint256 exposureAfter = aaveModule.currentExposure(address(token));

        // INVARIANT: Exposure reduced by original deposit
        assertEq(exposureBefore - exposureAfter, deposit, 'Exposure should decrease by deposit');
    }
}
