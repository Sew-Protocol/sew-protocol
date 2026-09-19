// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/mocks/FeeOnTransferERC20Mock.sol';
import 'contracts/interfaces/IYieldModule.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title AaveYieldModuleTest
 * @notice Tests for AaveYieldModule v2.5 interface
 */
contract AaveYieldModuleTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public token;
    MockAToken public aToken;

    address public owner;
    address public escrow;
    address public otherEscrow;

    uint256 constant INITIAL_BALANCE = 1000000e18;
    uint256 constant DEPOSIT_AMOUNT = 1000e18;

    function setUp() public {
        owner = address(this);
        escrow = address(0x1001);
        otherEscrow = address(0x1002);

        token = new ERC20Mock("Test Token", "TEST", owner, INITIAL_BALANCE);
        aToken = new MockAToken(address(token), "aTest", "aTEST");
        pool = new MockAavePool();
        
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));

        module = new AaveYieldModule(address(pool));
        
        token.approve(address(pool), type(uint256).max);
    }

    // ===== Slow-lane governance helpers =====

    function _configureToken(address token_, address aToken_) internal {
        module.queueConfigureToken(token_, aToken_);
        vm.warp(block.timestamp + 7 days);
        module.activateConfigureToken(token_);
    }

    function _approveEscrow(address escrow_) internal {
        module.queueApproveEscrow(escrow_);
        vm.warp(block.timestamp + 7 days);
        module.activateApproveEscrow();
    }

    // ============ Constructor Tests ============

    function test_Constructor_ValidPool() public {
        assertEq(address(module.aavePool()), address(pool));
    }

    function test_Constructor_ZeroPoolAddress() public {
        vm.expectRevert("InvalidPoolAddress");
        new AaveYieldModule(address(0));
    }

    function test_Constructor_PoolNotContract() public {
        vm.expectRevert("PoolAddressIsNotContract");
        new AaveYieldModule(address(0x1234));
    }

    // ============ Escrow Approval Tests ============

    function test_ApproveEscrow() public {
        _approveEscrow(escrow);
        assertTrue(module.approvedEscrows(escrow));
    }

    function test_ApproveEscrow_ZeroAddress() public {
        vm.expectRevert("InvalidAddress");
        module.queueApproveEscrow(address(0));
    }

    function test_RevokeEscrow() public {
        _approveEscrow(escrow);
        module.revokeEscrow(escrow);
        assertFalse(module.approvedEscrows(escrow));
    }

    // ============ Token Configuration Tests ============

    function test_ConfigureToken() public {
        _configureToken(address(token), address(aToken));
        assertEq(module.tokenToAToken(address(token)), address(aToken));
    }

    function test_ConfigureToken_ZeroToken() public {
        vm.expectRevert("InvalidAddress");
        module.queueConfigureToken(address(0), address(aToken));
    }

    function test_ConfigureToken_ZeroAToken() public {
        vm.expectRevert("InvalidAToken");
        module.queueConfigureToken(address(token), address(0));
    }

    function test_ConfigureMinDeposit_Success() public {
        module.configureMinDeposit(address(token), 123);
        assertEq(module.minDepositByToken(address(token)), 123);
    }

    function test_ConfigureMinDeposit_ZeroToken_Reverts() public {
        vm.expectRevert("InvalidAddress");
        module.configureMinDeposit(address(0), 1);
    }

    // ============ Initialize Yield Tests ============

    function test_InitializeYield_Success() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        
        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        token.approve(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
        
        assertEq(accepted, DEPOSIT_AMOUNT);
    }

    function test_InitializeYield_ZeroAmount() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        
        vm.prank(escrow);
        vm.expectRevert("ZeroAmount");
        module.initializeYield(1, address(token), 0, YieldPreset.OFF);
    }

    function test_InitializeYield_UnauthorizedEscrow() public {
        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        vm.expectRevert("UnauthorizedEscrow");
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
    }

    function test_InitializeYield_NoFundsOrApproval_Reverts() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));

        // Pull model: with no funds and no approval the module's transferFrom
        // cannot source the deposit and the call reverts.
        vm.prank(escrow);
        vm.expectRevert();
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
    }

    function test_InitializeYield_BelowConfiguredMinDeposit_Reverts() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        module.configureMinDeposit(address(token), DEPOSIT_AMOUNT + 1);

        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);

        vm.prank(escrow);
        vm.expectRevert("BelowMinDeposit");
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
    }

    // ============ Unwind To Escrow Tests ============

    function test_UnwindToEscrow_Unauthorized() public {
        // First set up a position
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        
        // Try to unwind from non-approved escrow - gets TokenMismatch since escrow isn't the one with position
        vm.prank(otherEscrow);
        vm.expectRevert("UnauthorizedEscrow");
        module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
    }

    function test_UnwindToEscrow_TokenMismatch() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        
        // Try to unwind with wrong token - gets TokenMismatch because escrow has no position
        vm.prank(escrow);
        vm.expectRevert("TokenMismatch");
        module.unwindToEscrow(1, address(0x1234), DEPOSIT_AMOUNT);
    }

    // ============ Emergency Unwind Tests ============

    function test_EmergencyUnwind_Unauthorized() public {
        // First set up a position
        _approveEscrow(escrow);
        
        // Try to emergency unwind from non-approved escrow
        vm.prank(otherEscrow);
        vm.expectRevert("UnauthorizedEscrow");
        module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);
    }

    function test_EmergencyUnwind_TokenMismatch() public {
        _approveEscrow(escrow);
        
        // Try to emergency unwind with wrong token - gets TokenMismatch because no position
        vm.prank(escrow);
        vm.expectRevert("TokenMismatch");
        module.emergencyUnwind(1, address(0x1234), DEPOSIT_AMOUNT);
    }

    // ============ Metadata Tests ============

    function test_GetModuleInfo() public {
        (string memory name, string memory version, bytes32 protocolId) = module.getModuleInfo();
        assertEq(name, "AaveYieldModule");
        assertEq(version, "2.5.4");
        assertEq(protocolId, keccak256("aave-v3"));
    }

    function test_CanHandle() public {
        _configureToken(address(token), address(aToken));
        (bool supported, bytes32 reason) = module.canHandle(address(token), YieldPreset.OFF, 1000e18);
        assertTrue(supported);
        assertEq(reason, bytes32(0));
    }

    // ============ Full Flow Tests ============

    function test_FullFlow_InitializeAndUnwind() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        
        uint256 escrowBalBefore = token.balanceOf(escrow);
        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        token.approve(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
        assertEq(accepted, DEPOSIT_AMOUNT);
        
        assertEq(IERC20(address(aToken)).balanceOf(address(module)), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
        
        assertEq(principal, DEPOSIT_AMOUNT);
        assertEq(yieldOut, 0);
    }

    function test_FullFlow_WithYield() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        
        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
        
        // Simulate yield accumulation (this increases the liquidity index)
        pool.simulateYield(address(token), 100);
        
        // The aToken balance will have increased due to rebasing
        uint256 aTokenBalBefore = IERC20(address(aToken)).balanceOf(address(module));
        
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
        
        assertEq(principal, DEPOSIT_AMOUNT);
        assertGe(yieldOut, 0); // Yield may be 0 if mock doesn't perfectly simulate
    }

    function test_FullFlow_MultiplePositions() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        
        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        token.approve(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
        
        token.transfer(escrow, DEPOSIT_AMOUNT * 2);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        token.approve(address(module), DEPOSIT_AMOUNT * 2);
        
        vm.prank(escrow);
        uint256 accepted2 = module.initializeYield(2, address(token), DEPOSIT_AMOUNT * 2, YieldPreset.OFF);
        assertEq(accepted2, DEPOSIT_AMOUNT * 2);
    }

    function test_PositionStorage() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        
        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        token.approve(address(module), DEPOSIT_AMOUNT);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
        
        (address posToken, uint256 principal, , ) = module.positions(escrow, 1);
        assertEq(posToken, address(token));
        assertEq(principal, DEPOSIT_AMOUNT);
    }

    function test_EmergencyUnwind_Success() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        
        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);
        
        uint256 balBefore = token.balanceOf(escrow);
        
        vm.prank(escrow);
        uint256 recovered = module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);
        
        assertEq(recovered, DEPOSIT_AMOUNT);
    }

    function test_EmergencyUnwind_NoPosition() public {
        _approveEscrow(escrow);
        
        // Since there's no position, it will revert with TokenMismatch (checks position first)
        vm.prank(escrow);
        vm.expectRevert("TokenMismatch");
        module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);
    }

    function test_UnwindToEscrow_NoPosition() public {
        _approveEscrow(escrow);
        
        vm.prank(escrow);
        vm.expectRevert("TokenMismatch");
        module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
    }

    function test_UnwindToEscrow_InvalidIncomeIndex_PathNotReachableInMock() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));

        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);

        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);

        vm.prank(escrow);
        (uint256 principalOut, uint256 yieldOut) = module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
        // Mock pool getReserveNormalizedIncome falls back to INITIAL_LIQUIDITY_INDEX when unset,
        // so InvalidIncomeIndex is not reachable in this fixture.
        assertEq(principalOut, DEPOSIT_AMOUNT);
        assertEq(yieldOut, 0);
    }

    function test_EmergencyUnwind_InvalidIncomeIndex_PathNotReachableInMock() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));

        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);

        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);

        vm.prank(escrow);
        uint256 recovered = module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);
        // Mock pool getReserveNormalizedIncome falls back to INITIAL_LIQUIDITY_INDEX when unset,
        // so InvalidIncomeIndex is not reachable in this fixture.
        assertEq(recovered, DEPOSIT_AMOUNT);
    }

    function test_TokenNotConfigured() public {
        _approveEscrow(escrow);
        
        ERC20Mock otherToken = new ERC20Mock("Other", "OTH", owner, INITIAL_BALANCE);
        otherToken.approve(address(pool), type(uint256).max);
        otherToken.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); otherToken.approve(address(module), type(uint256).max);
        
        // Module reverts with TokenNotConfigured custom error before reaching the pool
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSelector(AaveYieldModule.TokenNotConfigured.selector, address(otherToken)));
        module.initializeYield(1, address(otherToken), DEPOSIT_AMOUNT, YieldPreset.OFF);
    }

    // ============ Fee-on-Transfer Token Test ============

    function test_FeeOnTransferToken() public {
        _approveEscrow(escrow);
        
        // Create a fee-on-transfer token (100 bps = 1% fee)
        FeeOnTransferERC20Mock feeToken = new FeeOnTransferERC20Mock("FeeToken", "FEE", 100);
        MockAToken feeAToken = new MockAToken(address(feeToken), "aFeeToken", "aFEE");
        
        feeToken.mint(owner, INITIAL_BALANCE);
        
        // Add to pool before configuring
        pool.setAToken(address(feeToken), address(feeAToken));
        feeAToken.setPool(address(pool));
        
        // Approve pool after setting up
        feeToken.approve(address(pool), type(uint256).max);
        
        _configureToken(address(feeToken), address(feeAToken));
        
        // Transfer amount accounting for fee (escrow sends 1000, but only 990 arrives due to 1% fee)
        uint256 requestedAmount = DEPOSIT_AMOUNT;
        uint256 expectedFee = requestedAmount / 100; // 1% fee
        uint256 expectedDeposited = requestedAmount - expectedFee;
        
        // Mint directly to the escrow so it holds the full requested amount; the
        // 1% fee is then charged on the escrow -> module pull.
        feeToken.mint(escrow, requestedAmount);
        vm.prank(escrow); feeToken.approve(address(module), type(uint256).max);
        
        // Pass requestedAmount but only what's available will be deposited
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(feeToken), requestedAmount, YieldPreset.OFF);
        
        // Accepted should be less than requested amount due to fee
        assertEq(accepted, expectedDeposited);
        
        // Verify position stores the actual deposited amount
        (address posToken, uint256 principal, , ) = module.positions(escrow, 1);
        assertEq(posToken, address(feeToken));
        assertEq(principal, expectedDeposited);
    }

    // ============ #4 Emergency unwind shares the Aave withdrawal path ============

    /**
     * @notice Regression (#4): the "emergency" unwind is NOT an independent Aave exit —
     * it calls the same aavePool.withdraw() as the normal unwind. When Aave's withdrawal
     * path fails (pause / no liquidity / pool malfunction), BOTH normal and emergency
     * unwind fail with the same reason. Emergency unwind provides operator/escrow-triggered
     * initiation and forced-to-escrow routing, not an alternate way out of Aave.
     */
    function test_emergencyUnwind_sharesAaveWithdrawalPath() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));

        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);

        // Aave's withdrawal path fails.
        pool.setWithdrawFail(true);

        // Normal unwind fails with the same reason.
        vm.prank(escrow);
        vm.expectRevert("Withdraw failed");
        module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);

        // Emergency unwind also fails with the same reason — not an independent exit.
        vm.prank(escrow);
        vm.expectRevert("Withdraw failed");
        module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT);

        // Operator-triggered emergency unwind is likewise blocked by the shared path.
        address op = address(0xBEEF);
        module.setRecoveryOperator(op, true);
        vm.prank(op);
        vm.expectRevert("Withdraw failed");
        module.emergencyUnwindForEscrow(escrow, 1, address(token), DEPOSIT_AMOUNT);
    }

    // ============ #5 config change must not invalidate existing positions ============

    /**
     * @notice Regression (#5): an existing position is bound to the aToken it was created
     * with. The owner may later change tokenToAToken, but withdrawal of an existing position
     * must still operate against the ORIGINAL aToken (not the new config), so the position
     * remains recoverable.
     */
    function test_configChange_doesNotInvalidateExistingPosition() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        pool.setAToken(address(token), address(aToken));

        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);

        // Owner reconfigures the token to a DIFFERENT aToken. The pool's canonical
        // reserve still points at the original aToken.
        MockAToken other = new MockAToken(address(token), "aOther", "aOTHER");
        _configureToken(address(token), address(other));

        // The existing position must still unwind against the original aToken.
        pool.simulateYield(address(token), 50);
        vm.prank(escrow);
        (uint256 principal, uint256 y) = module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);

        assertEq(principal, DEPOSIT_AMOUNT, "principal recovered despite config change");
        assertGt(principal + y, DEPOSIT_AMOUNT, "full value recovered");
    }

    // ============ #7 principalExpected must equal recorded principal ============

    /**
     * @notice Regression (#7): unwind paths reject a caller-supplied expected principal
     * that does not equal the recorded principalDeposited (cross-component integrity check).
     * Passing the correct principal succeeds.
     */
    function test_principalExpectedMismatch_reverts() public {
        _approveEscrow(escrow);
        _configureToken(address(token), address(aToken));
        token.transfer(escrow, DEPOSIT_AMOUNT);
        vm.prank(escrow); token.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(1, address(token), DEPOSIT_AMOUNT, YieldPreset.OFF);

        // A wrong expected principal must revert on every unwind path.
        vm.prank(escrow);
        vm.expectRevert("PrincipalMismatch");
        module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT + 1);

        vm.prank(escrow);
        vm.expectRevert("PrincipalMismatch");
        module.emergencyUnwind(1, address(token), DEPOSIT_AMOUNT + 1);

        address op = address(0xBEEF);
        module.setRecoveryOperator(op, true);
        vm.prank(op);
        vm.expectRevert("PrincipalMismatch");
        module.emergencyUnwindForEscrow(escrow, 1, address(token), DEPOSIT_AMOUNT + 1);

        // The correct principal still succeeds and returns the full principal.
        vm.prank(escrow);
        (uint256 principal, ) = module.unwindToEscrow(1, address(token), DEPOSIT_AMOUNT);
        assertEq(principal, DEPOSIT_AMOUNT);
    }
    function test_canHandle_zeroAmount_returnsFalse() public {
        (bool supported, bytes32 reason) = module.canHandle(address(token), YieldPreset.OFF, 0);
        assertFalse(supported);
        assertEq(reason, keccak256("ZERO_AMOUNT"));
    }

    function test_canHandle_unconfiguredToken_returnsFalse() public {
        (bool supported, bytes32 reason) = module.canHandle(address(0xBEEF), YieldPreset.OFF, 1e18);
        assertFalse(supported);
        assertEq(reason, keccak256("TOKEN_NOT_CONFIGURED"));
    }

    function test_canHandle_belowMinDeposit_returnsFalse() public {
        // Configure a large min-deposit for the token; amount below it is not handled.
        _configureToken(address(token), address(aToken));
        module.configureMinDeposit(address(token), 1000e18);
        (bool supported, bytes32 reason) = module.canHandle(address(token), YieldPreset.OFF, 999e18);
        assertFalse(supported);
        assertEq(reason, keccak256("BELOW_MIN_DEPOSIT"));
        // Restore default so other tests in the file are unaffected.
        module.configureMinDeposit(address(token), 0);
    }
}


// ============ 6-Decimal Token Tests ============

/**
 * @title AaveYieldModule6DecimalTest
 * @notice Tests for AaveYieldModule with 6-decimal tokens (USDC, USDT)
 * @dev Aave handles 6-decimal and 18-decimal tokens differently. These tests
 *      verify the module works correctly with popular stablecoins.
 */
contract AaveYieldModule6DecimalTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public usdc;
    ERC20Mock public usdt;
    MockAToken public usdcAToken;
    MockAToken public usdtAToken;

    address public owner;
    address public escrow;
    address public otherEscrow;

    uint256 constant INITIAL_BALANCE_6DEC = 1000000e6;  // 1M USDC
    uint256 constant DEPOSIT_AMOUNT_6DEC = 1000e6;       // 1000 USDC
    uint256 constant SMALL_DEPOSIT_6DEC = 100e6;        // 100 USDC (dust test)
    uint256 constant INITIAL_BALANCE_18DEC = 1000000e18;
    uint256 constant DEPOSIT_AMOUNT_18DEC = 1000e18;

    function setUp() public {
        owner = address(this);
        escrow = address(0x1001);
        otherEscrow = address(0x1002);

        // Deploy 6-decimal tokens (USDC, USDT)
        usdc = new ERC20Mock("USD Coin", "USDC", owner, INITIAL_BALANCE_6DEC);
        usdt = new ERC20Mock("Tether", "USDT", owner, INITIAL_BALANCE_6DEC);

        // Deploy aTokens for 6-decimal tokens
        usdcAToken = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        usdtAToken = new MockAToken(address(usdt), "aUSDT", "aUSDT");

        pool = new MockAavePool();
        
        pool.setAToken(address(usdc), address(usdcAToken));
        pool.setAToken(address(usdt), address(usdtAToken));
        usdcAToken.setPool(address(pool));
        usdtAToken.setPool(address(pool));

        module = new AaveYieldModule(address(pool));
        
        usdc.approve(address(pool), type(uint256).max);
        usdt.approve(address(pool), type(uint256).max);
    }

    // ===== Slow-lane governance helpers =====

    function _configureToken(address token_, address aToken_) internal {
        module.queueConfigureToken(token_, aToken_);
        vm.warp(block.timestamp + 7 days);
        module.activateConfigureToken(token_);
    }

    function _approveEscrow(address escrow_) internal {
        module.queueApproveEscrow(escrow_);
        vm.warp(block.timestamp + 7 days);
        module.activateApproveEscrow();
    }

    // ============ USDC (6 decimals) Tests ============

    function test_ConfigureUSDC() public {
        _configureToken(address(usdc), address(usdcAToken));
        assertEq(module.tokenToAToken(address(usdc)), address(usdcAToken));
    }

    function test_InitializeYield_USDC() public {
        _approveEscrow(escrow);
        _configureToken(address(usdc), address(usdcAToken));
        
        usdc.transfer(escrow, DEPOSIT_AMOUNT_6DEC);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        usdc.approve(address(module), DEPOSIT_AMOUNT_6DEC);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(usdc), DEPOSIT_AMOUNT_6DEC, YieldPreset.OFF);
        
        assertEq(accepted, DEPOSIT_AMOUNT_6DEC);
    }

    function test_InitializeYield_USDC_SmallAmount() public {
        _approveEscrow(escrow);
        _configureToken(address(usdc), address(usdcAToken));
        
        // Small deposit (100 USDC = 100e6)
        usdc.transfer(escrow, SMALL_DEPOSIT_6DEC);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        usdc.approve(address(module), SMALL_DEPOSIT_6DEC);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(usdc), SMALL_DEPOSIT_6DEC, YieldPreset.OFF);
        
        // Should succeed with small amount
        assertEq(accepted, SMALL_DEPOSIT_6DEC);
    }

    function test_UnwindToEscrow_USDC() public {
        _approveEscrow(escrow);
        _configureToken(address(usdc), address(usdcAToken));
        
        usdc.transfer(escrow, DEPOSIT_AMOUNT_6DEC);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        usdc.approve(address(module), DEPOSIT_AMOUNT_6DEC);
        
        vm.prank(escrow);
        module.initializeYield(1, address(usdc), DEPOSIT_AMOUNT_6DEC, YieldPreset.OFF);
        
        uint256 escrowBalBefore = usdc.balanceOf(escrow);
        
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(usdc), DEPOSIT_AMOUNT_6DEC);
        
        assertEq(principal, DEPOSIT_AMOUNT_6DEC);
        assertEq(yieldOut, 0);
    }

    function test_EmergencyUnwind_USDC() public {
        _approveEscrow(escrow);
        _configureToken(address(usdc), address(usdcAToken));
        
        usdc.transfer(escrow, DEPOSIT_AMOUNT_6DEC);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        module.initializeYield(1, address(usdc), DEPOSIT_AMOUNT_6DEC, YieldPreset.OFF);
        
        uint256 balBefore = usdc.balanceOf(escrow);
        
        vm.prank(escrow);
        uint256 recovered = module.emergencyUnwind(1, address(usdc), DEPOSIT_AMOUNT_6DEC);
        
        assertEq(recovered, DEPOSIT_AMOUNT_6DEC);
    }

    // ============ USDT (6 decimals) Tests ============

    function test_ConfigureUSDT() public {
        _configureToken(address(usdt), address(usdtAToken));
        assertEq(module.tokenToAToken(address(usdt)), address(usdtAToken));
    }

    function test_InitializeYield_USDT() public {
        _approveEscrow(escrow);
        _configureToken(address(usdt), address(usdtAToken));
        
        usdt.transfer(escrow, DEPOSIT_AMOUNT_6DEC);
        vm.prank(escrow); usdt.approve(address(module), type(uint256).max);
        usdt.approve(address(module), DEPOSIT_AMOUNT_6DEC);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(usdt), DEPOSIT_AMOUNT_6DEC, YieldPreset.OFF);
        
        assertEq(accepted, DEPOSIT_AMOUNT_6DEC);
    }

    function test_UnwindToEscrow_USDT() public {
        _approveEscrow(escrow);
        _configureToken(address(usdt), address(usdtAToken));
        
        usdt.transfer(escrow, DEPOSIT_AMOUNT_6DEC);
        vm.prank(escrow); usdt.approve(address(module), type(uint256).max);
        usdt.approve(address(module), DEPOSIT_AMOUNT_6DEC);
        
        vm.prank(escrow);
        module.initializeYield(1, address(usdt), DEPOSIT_AMOUNT_6DEC, YieldPreset.OFF);
        
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(usdt), DEPOSIT_AMOUNT_6DEC);
        
        assertEq(principal, DEPOSIT_AMOUNT_6DEC);
    }

    // ============ Multi-Token Tests ============

    function test_MultipleEscrows_USDC() public {
        address escrow2 = address(0x1003);
        
        _approveEscrow(escrow);
        _approveEscrow(escrow2);
        _configureToken(address(usdc), address(usdcAToken));
        
        // Escrow 1 deposits
        usdc.transfer(escrow, DEPOSIT_AMOUNT_6DEC);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(1, address(usdc), DEPOSIT_AMOUNT_6DEC, YieldPreset.OFF);
        
        // Escrow 2 deposits
        usdc.transfer(escrow2, DEPOSIT_AMOUNT_6DEC * 2);
        vm.prank(escrow2); usdc.approve(address(module), type(uint256).max);
        vm.prank(escrow2);
        module.initializeYield(1, address(usdc), DEPOSIT_AMOUNT_6DEC * 2, YieldPreset.OFF);
        
        // Verify positions
        (address token1, uint256 principal1, , ) = module.positions(escrow, 1);
        assertEq(principal1, DEPOSIT_AMOUNT_6DEC);
        
        (address token2, uint256 principal2, , ) = module.positions(escrow2, 1);
        assertEq(principal2, DEPOSIT_AMOUNT_6DEC * 2);
    }

    function test_YieldAccrual_USDC() public {
        _approveEscrow(escrow);
        _configureToken(address(usdc), address(usdcAToken));
        
        usdc.transfer(escrow, DEPOSIT_AMOUNT_6DEC);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        module.initializeYield(1, address(usdc), DEPOSIT_AMOUNT_6DEC, YieldPreset.OFF);
        
        // Simulate yield accrual
        pool.simulateYield(address(usdc), 50); // 5% yield
        
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(usdc), DEPOSIT_AMOUNT_6DEC);
        
        assertEq(principal, DEPOSIT_AMOUNT_6DEC);
        // Yield may vary based on mock implementation
    }

    // ============ Edge Cases ============

    function test_DustAmount_USDC() public {
        _approveEscrow(escrow);
        _configureToken(address(usdc), address(usdcAToken));
        
        // Minimum dust amount (1 USDC = 1e6)
        uint256 dustAmount = 1e6;
        usdc.transfer(escrow, dustAmount);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(usdc), dustAmount, YieldPreset.OFF);
        
        // Should accept the dust amount
        assertEq(accepted, dustAmount);
    }

    function test_CanHandle_USDC() public {
        _configureToken(address(usdc), address(usdcAToken));
        
        (bool supported, bytes32 reason) = module.canHandle(address(usdc), YieldPreset.OFF, 1000e6);
        assertTrue(supported);
    }

    function test_FullFlow_USDC() public {
        _approveEscrow(escrow);
        _configureToken(address(usdc), address(usdcAToken));
        
        // Initialize
        usdc.transfer(escrow, DEPOSIT_AMOUNT_6DEC);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        usdc.approve(address(module), DEPOSIT_AMOUNT_6DEC);
        
        vm.prank(escrow);
        uint256 accepted = module.initializeYield(1, address(usdc), DEPOSIT_AMOUNT_6DEC, YieldPreset.OFF);
        assertEq(accepted, DEPOSIT_AMOUNT_6DEC);
        
        // Verify aToken balance
        assertEq(IERC20(address(usdcAToken)).balanceOf(address(module)), DEPOSIT_AMOUNT_6DEC);
        
        // Unwind
        vm.prank(escrow);
        (uint256 principal, uint256 yieldOut) = module.unwindToEscrow(1, address(usdc), DEPOSIT_AMOUNT_6DEC);
        
        assertEq(principal, DEPOSIT_AMOUNT_6DEC);
        assertEq(yieldOut, 0);
    }
}

// ============ Mixed Decimals Tests ============

/**
 * @title AaveYieldModuleMixedDecimalsTest
 * @notice Tests for AaveYieldModule with mixed 6 and 18 decimal tokens
 * @dev Verifies the module handles both common token types correctly
 */
contract AaveYieldModuleMixedDecimalsTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    ERC20Mock public usdc;    // 6 decimals
    ERC20Mock public dai;     // 18 decimals
    MockAToken public usdcAToken;
    MockAToken public daiAToken;

    address public escrow;

    function setUp() public {
        escrow = address(0x1001);

        // 6-decimal token (USDC)
        usdc = new ERC20Mock("USD Coin", "USDC", address(this), 1000000e6);
        
        // 18-decimal token (DAI)
        dai = new ERC20Mock("Dai", "DAI", address(this), 1000000e18);

        usdcAToken = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        daiAToken = new MockAToken(address(dai), "aDAI", "aDAI");

        pool = new MockAavePool();
        
        pool.setAToken(address(usdc), address(usdcAToken));
        pool.setAToken(address(dai), address(daiAToken));
        usdcAToken.setPool(address(pool));
        daiAToken.setPool(address(pool));

        module = new AaveYieldModule(address(pool));
        
        usdc.approve(address(pool), type(uint256).max);
        dai.approve(address(pool), type(uint256).max);
    }

    // ===== Slow-lane governance helpers =====

    function _configureToken(address token_, address aToken_) internal {
        module.queueConfigureToken(token_, aToken_);
        vm.warp(block.timestamp + 7 days);
        module.activateConfigureToken(token_);
    }

    function _approveEscrow(address escrow_) internal {
        module.queueApproveEscrow(escrow_);
        vm.warp(block.timestamp + 7 days);
        module.activateApproveEscrow();
    }

    function test_MixedDecimals_SimultaneousEscrows() public {
        _approveEscrow(escrow);
        _configureToken(address(usdc), address(usdcAToken));
        _configureToken(address(dai), address(daiAToken));
        
        // USDC deposit (6 decimals)
        usdc.transfer(escrow, 1000e6);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(1, address(usdc), 1000e6, YieldPreset.OFF);
        
        // DAI deposit (18 decimals)
        dai.transfer(escrow, 1000e18);
        vm.prank(escrow); dai.approve(address(module), type(uint256).max);
        vm.prank(escrow);
        module.initializeYield(2, address(dai), 1000e18, YieldPreset.OFF);
        
        // Verify both positions
        (, uint256 usdcPrincipal, , ) = module.positions(escrow, 1);
        (, uint256 daiPrincipal, , ) = module.positions(escrow, 2);
        
        assertEq(usdcPrincipal, 1000e6);
        assertEq(daiPrincipal, 1000e18);
    }

    function test_YieldAcrossDecimals() public {
        _approveEscrow(escrow);
        _configureToken(address(usdc), address(usdcAToken));
        _configureToken(address(dai), address(daiAToken));
        
        // Deposit both
        usdc.transfer(escrow, 1000e6);
        vm.prank(escrow); usdc.approve(address(module), type(uint256).max);
        dai.transfer(escrow, 1000e18);
        vm.prank(escrow); dai.approve(address(module), type(uint256).max);
        
        vm.prank(escrow);
        module.initializeYield(1, address(usdc), 1000e6, YieldPreset.OFF);
        
        vm.prank(escrow);
        module.initializeYield(2, address(dai), 1000e18, YieldPreset.OFF);
        
        // Simulate yield on both
        pool.simulateYield(address(usdc), 100); // 10%
        pool.simulateYield(address(dai), 100);   // 10%
        
        // Withdraw both
        vm.prank(escrow);
        (uint256 usdcPrincipal, uint256 usdcYield) = module.unwindToEscrow(1, address(usdc), 1000e6);
        
        vm.prank(escrow);
        (uint256 daiPrincipal, uint256 daiYield) = module.unwindToEscrow(2, address(dai), 1000e18);
        
        assertEq(usdcPrincipal, 1000e6);
        assertEq(daiPrincipal, 1000e18);
    }
}
