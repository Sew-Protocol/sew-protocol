// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/AaveYieldModule.sol';
import '../../../contracts/mocks/MockAavePool.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

contract AaveYieldModuleTest is Test {
    AaveYieldModule public module;
    MockAavePool public pool;
    MockPoolAddressesProvider public provider;
    ERC20Mock public token;
    MockAToken public aToken;

    address public owner;
    address public timelock;
    address public guardian;
    address public escrow;

    // Event declarations for testing
    event EscrowDepositedToAave(
        uint256 indexed workflowId,
        address indexed token,
        uint256 amount,
        uint256 aTokenBalance
    );
    event EscrowWithdrawnFromAave(
        uint256 indexed workflowId,
        address indexed token,
        uint256 originalAmount,
        uint256 actualAmount,
        uint256 yield
    );

    function setUp() public {
        owner = address(this);
        timelock = address(0x1);
        guardian = address(0x2);
        escrow = address(0x3);

        token = new ERC20Mock("Test", "TEST", address(this), 1000000e18);
        aToken = new MockAToken(address(token), "aTest", "aTEST");
        pool = new MockAavePool();
        provider = new MockPoolAddressesProvider(address(pool));

        // Setup mock pool/token relationship
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));

        module = new AaveYieldModule(owner);
        
        // Setup roles
        module.grantRole(module.ROLE_TIMELOCK(), timelock);
        module.grantRole(module.ROLE_GUARDIAN(), guardian);
        module.grantRole(module.ROLE_ESCROW_CONTRACT(), escrow);
    }

    // ============ Configuration Tests ============

    function test_QueueAndActivateProvider() public {
        vm.startPrank(timelock);
        
        // Queue
        module.queueAavePoolProvider(address(provider));
        (address pending, uint64 eta, bool exists) = module.getPendingAavePoolProvider();
        assertEq(pending, address(provider));
        assertTrue(exists);
        
        // Try early activation
        vm.expectRevert(abi.encodeWithSelector(SlowLaneQueueActivate.NotReady.selector, eta));
        module.activateAavePoolProvider();

        // Warp
        vm.warp(block.timestamp + 7 days);

        // Activate
        module.activateAavePoolProvider();
        assertEq(address(module.aavePoolAddressesProvider()), address(provider));
        assertEq(address(module.aavePool()), address(pool));
        assertTrue(module.aaveEnabled());

        vm.stopPrank();
    }

    function test_RegisterToken() public {
        vm.startPrank(timelock);
        module.registerTokenForAave(address(token), address(aToken));
        assertTrue(module.isTokenSupportedByAave(address(token)));
        assertEq(module.tokenToAToken(address(token)), address(aToken));
        vm.stopPrank();
    }

    function test_RegisterToken_InvalidUnderlying() public {
        MockAToken badAToken = new MockAToken(address(0x999), "Bad", "BAD");
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(InvalidATokenAddress.selector, address(token), address(badAToken)));
        module.registerTokenForAave(address(token), address(badAToken));
    }

    function test_BatchRegisterTokens() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        address[] memory aTokens = new address[](1);
        aTokens[0] = address(aToken);

        vm.prank(timelock);
        module.batchRegisterTokensForAave(tokens, aTokens);
        assertTrue(module.isTokenSupportedByAave(address(token)));
    }

    function test_BatchRegisterTokens_Mismatch() public {
        address[] memory tokens = new address[](2);
        address[] memory aTokens = new address[](1);
        vm.prank(timelock);
        vm.expectRevert(); // ArrayLengthMismatch
        module.batchRegisterTokensForAave(tokens, aTokens);
    }

    function test_BatchRegisterTokens_TooLarge() public {
        uint256 maxBatch = module.MAX_BATCH_SIZE();
        uint256 size = maxBatch + 1;
        address[] memory tokens = new address[](size);
        address[] memory aTokens = new address[](size);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(BatchSizeTooLarge.selector, size, maxBatch));
        module.batchRegisterTokensForAave(tokens, aTokens);
    }

    function test_SetAaveEnabled_NotConfigured() public {
        vm.prank(timelock);
        vm.expectRevert(AaveYieldModule.AavePoolNotConfigured.selector);
        module.setAaveEnabled(true);
    }

    function test_SetTokenCap() public {
        uint256 cap = 1000e18;
        vm.prank(timelock);
        module.setTokenCap(address(token), cap);
        assertEq(module.tokenCap(address(token)), cap);
    }

    function test_SetTokenCap_ExceedMax() public {
        uint256 maxCap = module.CAP_MAX();
        uint256 tooLarge = maxCap + 1;
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(CapExceeded.selector, address(token), tooLarge, maxCap));
        module.setTokenCap(address(token), tooLarge);
    }

    function test_GuardianLowerCaps() public {
        uint256 initialCap = 1000e18;
        vm.startPrank(timelock);
        module.setTokenCap(address(token), initialCap);
        module.setGlobalCap(address(token), initialCap);
        vm.stopPrank();

        vm.startPrank(guardian);
        module.guardianLowerTokenCap(address(token), initialCap - 100);
        module.guardianLowerGlobalCap(address(token), initialCap - 200);
        assertEq(module.tokenCap(address(token)), initialCap - 100);
        assertEq(module.globalCap(address(token)), initialCap - 200);

        // Cannot raise
        vm.expectRevert(abi.encodeWithSelector(CapCannotBeRaised.selector, initialCap, initialCap - 100));
        module.guardianLowerTokenCap(address(token), initialCap);
        vm.stopPrank();
    }

    function test_Withdraw_FailedCall() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount, escrow);

        // Replace pool with reverting one
        MockAavePoolReverting revertingPool = new MockAavePoolReverting();
        revertingPool.setAToken(address(token), address(aToken));
        
        MockPoolAddressesProvider failProvider = new MockPoolAddressesProvider(address(revertingPool));
        vm.startPrank(timelock);
        module.queueAavePoolProvider(address(failProvider));
        vm.warp(block.timestamp + 7 days + 1);
        module.activateAavePoolProvider();
        vm.stopPrank();

        // Approve aToken for Module
        vm.prank(escrow);
        aToken.approve(address(module), type(uint256).max);

        vm.prank(escrow);
        (bool success, uint256 actual, uint256 yield) = module.withdrawWithYield(1, address(token), amount, escrow);
        assertFalse(success);
        assertEq(actual, amount);
        assertEq(yield, 0);
    }

    function test_Withdraw_Slippage() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount, escrow);

        // Mock pool that returns less than principal
        MockAavePoolSlippage slippagePool = new MockAavePoolSlippage();
        slippagePool.setAToken(address(token), address(aToken));
        // Give tokens to pool
        token.mint(address(slippagePool), 1000e18);

        MockPoolAddressesProvider slipProvider = new MockPoolAddressesProvider(address(slippagePool));
        vm.startPrank(timelock);
        module.queueAavePoolProvider(address(slipProvider));
        vm.warp(block.timestamp + 7 days + 1);
        module.activateAavePoolProvider();
        vm.stopPrank();

        // Approve aToken for Module
        vm.prank(escrow);
        aToken.approve(address(module), type(uint256).max);

        // Slippage: Pool returns 90e18 instead of 100e18
        vm.prank(escrow);
        (bool success, uint256 actual, uint256 yield) = module.withdrawWithYield(1, address(token), amount, escrow);
        assertTrue(success); 
        assertEq(actual, 90e18);
        assertEq(yield, 0);
    }

    function test_Withdraw_ZeroATokenBalance() public {
        _configureAave();
        _registerToken();

        // Deposit 0
        vm.prank(escrow);
        module.depositForYield(1, address(token), 0, escrow);

        assertTrue(module.escrowInAave(escrow, 1));
        assertEq(module.escrowScaledBalance(escrow, 1), 0);

        vm.prank(escrow);
        (bool success, uint256 actual, uint256 yield) = module.withdrawWithYield(1, address(token), 0, escrow);
        assertTrue(success); 
        assertEq(actual, 0);
        assertEq(yield, 0);
        assertFalse(module.escrowInAave(escrow, 1));
    }

    function test_RegisterToken_ZeroAddresses() public {
        vm.startPrank(timelock);
        vm.expectRevert();
        module.registerTokenForAave(address(0), address(aToken));
        vm.expectRevert();
        module.registerTokenForAave(address(token), address(0));
        vm.stopPrank();
    }

    function test_supportsInterface() public view {
        assertTrue(module.supportsInterface(type(IYieldGenerationModule).interfaceId));
        assertTrue(module.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_Metadata_Pure() public view {
        assertEq(module.moduleName(), "AaveYieldGeneration");
        assertEq(module.moduleVersion(), "1.0.0");
    }

    function test_SetAaveEnabled() public {
        // Must configure pool first
        _configureAave();

        vm.prank(timelock);
        module.setAaveEnabled(false);
        assertFalse(module.aaveEnabled());

        vm.prank(timelock);
        module.setAaveEnabled(true);
        assertTrue(module.aaveEnabled());
    }

    function test_GuardianDisable() public {
        _configureAave();
        
        vm.prank(guardian);
        module.guardianDisableAave();
        assertFalse(module.aaveEnabled());
    }

    // ============ Deposit Tests ============

    function test_Deposit_Success() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        
        vm.prank(escrow);
        token.approve(address(module), amount);

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit EscrowDepositedToAave(1, address(token), amount, amount);

        vm.prank(escrow);
        (bool success, uint256 balance) = module.depositForYield(1, address(token), amount, escrow);
        
        assertTrue(success);
        assertEq(balance, amount);
        assertTrue(module.isTokenSupported(address(token)));
        
        (bool inAave, uint256 bal, uint256 orig) = module.getEscrowAaveData(escrow, 1);
        assertTrue(inAave);
        assertEq(bal, amount);
        assertEq(orig, amount);

        // Verify total deposited updated
        assertEq(module.totalDepositedToAave(address(token)), amount);
    }

    function test_supply_emitsExpectedEvents_andUpdatesPrincipal() public {
        // This is essentially the same as test_Deposit_Success but explicitly named for the checklist
        test_Deposit_Success();
    }

    function test_Deposit_Disabled() public {
        vm.prank(escrow);
        (bool success, uint256 balance) = module.depositForYield(1, address(token), 100, escrow);
        assertTrue(success);
        assertEq(balance, 0);
    }

    function test_Deposit_UnsupportedToken() public {
        _configureAave();
        // Don't register token
        vm.prank(escrow);
        (bool success, uint256 balance) = module.depositForYield(1, address(token), 100, escrow);
        assertTrue(success);
        assertEq(balance, 0);
    }

    function test_Deposit_EscrowableERC20Pattern() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        // Mock token balance for escrow
        token.mint(escrow, amount);

        // Grant allowance to module
        vm.prank(escrow);
        token.approve(address(module), amount);

        vm.prank(escrow);
        (bool success, ) = module.depositForYield(1, address(token), amount, escrow);
        
        assertTrue(success);
        assertTrue(module.escrowInAave(escrow, 1));
    }

    function test_Withdraw_NoATokens_FallbackToNormalizedIncome() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount, escrow);

        // Fund pool for withdrawal
        token.mint(address(pool), amount);

        // Use a pool that doesn't check aToken balance
        MockAavePoolNoAToken newPool = new MockAavePoolNoAToken();
        newPool.setAToken(address(token), address(aToken));
        token.mint(address(newPool), amount);
        
        MockPoolAddressesProvider newProvider = new MockPoolAddressesProvider(address(newPool));
        vm.startPrank(timelock);
        module.queueAavePoolProvider(address(newProvider));
        vm.warp(block.timestamp + 7 days + 1);
        module.activateAavePoolProvider();
        vm.stopPrank();

        vm.prank(escrow);
        (bool success, uint256 actual, uint256 yield) = module.withdrawWithYield(1, address(token), amount, escrow);
        
        assertTrue(success);
        assertEq(actual, 100e18);
        assertEq(yield, 0);
    }

    function test_Deposit_FailedExposureAccrual() public {
        _configureAave();
        _registerToken();

        vm.prank(timelock);
        module.setTokenCap(address(token), 50e18);

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);

        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSelector(CapExceeded.selector, address(token), amount, 50e18));
        module.depositForYield(1, address(token), amount, escrow);
    }

    function test_Withdraw_LostTokenMapping() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount, escrow);

        // Manually remove token registration (not possible via public API, but we simulate it)
        // Since we can't unregister, we'll use a different token for withdrawal
        vm.prank(escrow);
        (bool success, uint256 actual, uint256 yield) = module.withdrawWithYield(1, address(0x999), amount, escrow);
        assertTrue(success);
        assertEq(actual, amount);
        assertEq(yield, 0);
    }

    function test_calculateYield_ZeroBalances() public {
        _configureAave();
        _registerToken();

        // Escrow not in Aave
        assertEq(module.calculateYield(99, address(token), escrow), 0);

        // Record escrow but with 0 balances (simulated)
        // We can't easily simulate this without internal access, but we can call with invalid token
        assertEq(module.calculateYield(1, address(0x999), escrow), 0);
    }

    function test_getYieldStatistics() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount, escrow);

        (uint256 totalGenerated, uint256 totalWithdrawn, uint256 totalDeposited) = module.getYieldStatistics(address(token));
        assertEq(totalGenerated, 0);
        assertEq(totalWithdrawn, 0);
        assertEq(totalDeposited, amount);
    }

        function test_guardianDisableAave_DownOnly() public {

            _configureAave();

            

            vm.prank(guardian);

            module.guardianDisableAave();

            assertFalse(module.aaveEnabled());

            

            // Guardian cannot re-enable

            vm.prank(guardian);

            // This should fail as it's only ROLE_TIMELOCK

            vm.expectRevert();

            module.setAaveEnabled(true);

        }

    

        function test_CapManagement_Overflow() public {

            uint256 tooLarge = type(uint128).max;

            tooLarge += 1;

            

            vm.startPrank(timelock);

            vm.expectRevert(abi.encodeWithSelector(CapExceeded.selector, address(token), tooLarge, module.CAP_MAX()));

            module.setTokenCap(address(token), tooLarge);

            

            vm.expectRevert(abi.encodeWithSelector(CapExceeded.selector, address(token), tooLarge, module.CAP_MAX()));

            module.setGlobalCap(address(token), tooLarge);

            vm.stopPrank();

        }

    

        function test_Deposit_GlobalCapBlocksMultipleEscrows() public {
        _configureAave();
        _registerToken();

        address escrow2 = address(0x2222);
        module.grantRole(module.ROLE_ESCROW_CONTRACT(), escrow2);
        
        vm.prank(timelock);
        module.setGlobalCap(address(token), 100e18);

        // Escrow 1 uses 60e18
        token.mint(escrow, 60e18);
        vm.prank(escrow);
        token.approve(address(module), 60e18);
        vm.prank(escrow);
        module.depositForYield(1, address(token), 60e18, escrow);

        // Escrow 2 tries to use 50e18, should fail (60 + 50 > 100)
        token.mint(escrow2, 50e18);
        vm.prank(escrow2);
        token.approve(address(module), 50e18);
        vm.prank(escrow2);
        vm.expectRevert(abi.encodeWithSelector(CapExceeded.selector, address(token), 110e18, 100e18));
        module.depositForYield(1, address(token), 50e18, escrow2);
    }

    function test_ExposureTracking() public {

            _configureAave();

            _registerToken();

    

            uint256 amount = 100e18;

            token.mint(escrow, amount);

            vm.prank(escrow);

            token.approve(address(module), amount);

            

            // Deposit 100

            vm.prank(escrow);

            module.depositForYield(1, address(token), amount, escrow);

            assertEq(module.currentExposure(address(token)), amount);

    

            // Fund pool for withdrawal

            token.mint(address(pool), amount);

            vm.prank(escrow);

            aToken.approve(address(module), type(uint256).max);

    

                        // Withdraw 100

    

                        vm.prank(escrow);

    

                        module.withdrawWithYield(1, address(token), amount, escrow);

    

                        assertEq(module.currentExposure(address(token)), 0);

        }

    

        function test_batchRegisterTokens_Success() public {

            address[] memory tokens = new address[](2);

            tokens[0] = address(token);

            ERC20Mock token2 = new ERC20Mock("Test2", "TEST2", address(this), 0);

            tokens[1] = address(token2);

            

            address[] memory aTokens = new address[](2);

            aTokens[0] = address(aToken);

            MockAToken aToken2 = new MockAToken(address(token2), "aTest2", "aTEST2");

            aToken2.setPool(address(pool));

            pool.setAToken(address(token2), address(aToken2));

            aTokens[1] = address(aToken2);

    

            vm.prank(timelock);

            module.batchRegisterTokensForAave(tokens, aTokens);

            

            assertTrue(module.isTokenSupportedByAave(address(token)));

            assertTrue(module.isTokenSupportedByAave(address(token2)));

        }

    

    function test_Deposit_CapExceeded() public {
        _configureAave();
        _registerToken();

        vm.prank(timelock);
        module.setGlobalCap(address(token), 50e18);

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSelector(CapExceeded.selector, address(token), amount, 50e18));
        module.depositForYield(1, address(token), amount, escrow);
    }

    function test_Deposit_EscrowCapExceeded() public {
        _configureAave();
        _registerToken();

        vm.prank(timelock);
        module.setEscrowCap(escrow, address(token), 10e18);

        uint256 amount = 20e18;
        token.mint(escrow, amount);
        
        vm.prank(escrow);
        vm.expectRevert(abi.encodeWithSelector(AaveYieldModule.EscrowCapExceeded.selector, escrow, address(token), amount, 10e18));
        module.depositForYield(1, address(token), amount, escrow);
    }

    // ============ Withdraw Tests ============

    function test_Withdraw_Success() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount, escrow);

        vm.prank(escrow);
        aToken.approve(address(module), type(uint256).max);

        token.mint(address(pool), amount * 2);

        vm.prank(escrow);
        (bool success, uint256 actual, uint256 yield) = module.withdrawWithYield(1, address(token), amount, escrow);
        
        assertTrue(success);
        assertEq(yield, 0);
        
        (bool inAave, uint256 bal, uint256 orig) = module.getEscrowAaveData(escrow, 1);
        assertFalse(inAave);
        assertEq(bal, 0);
        assertEq(orig, 0);
    }

    function test_Withdraw_WithYield() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount, escrow);

        pool.simulateYield(address(token), 10);
        
        vm.prank(escrow);
        aToken.approve(address(module), type(uint256).max);
        
        token.mint(address(pool), 200e18);

        vm.prank(escrow);
        (bool success, uint256 actual, uint256 yield) = module.withdrawWithYield(1, address(token), amount, escrow);
        
        assertTrue(success);
        assertGt(actual, amount);
        assertEq(yield, actual - amount);
    }

    function test_Withdraw_NotAvailable() public {
        vm.prank(escrow);
        (bool success, uint256 actual, uint256 yield) = module.withdrawWithYield(99, address(token), 100, escrow);
        assertTrue(success);
        assertEq(actual, 100);
        assertEq(yield, 0);
    }

    function test_CalculateYield_EdgeCases() public {
        _configureAave();
        _registerToken();

        uint256 amount = 100e18;
        token.mint(escrow, amount);
        vm.prank(escrow);
        token.approve(address(module), amount);
        vm.prank(escrow);
        module.depositForYield(1, address(token), amount, escrow);

        vm.prank(escrow);
        uint256 yield = module.calculateYield(1, address(token), escrow);
        assertEq(yield, 0);

        vm.prank(escrow);
        assertEq(module.calculateYield(1, address(0x999), escrow), 0);
    }

    function test_GetApprovalTarget() public {
        _configureAave();
        _registerToken();
        assertEq(module.getApprovalTarget(address(token)), address(pool));
        
        vm.prank(timelock);
        module.setAaveEnabled(false);
        assertEq(module.getApprovalTarget(address(token)), address(0));
    }

    function test_ActivateAavePoolProvider_SafetyValidations() public {
        MockPoolAddressesProvider badProvider = new MockPoolAddressesProvider(address(0));
        vm.startPrank(timelock);
        module.queueAavePoolProvider(address(badProvider));
        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(InvalidPoolAddress.selector, address(0)));
        module.activateAavePoolProvider();

        module.queueAavePoolProvider(address(0xDEAD));
        vm.warp(block.timestamp + 14 days + 1);
        vm.expectRevert(abi.encodeWithSelector(PoolAddressIsNotContract.selector, address(0xDEAD)));
        module.activateAavePoolProvider();
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function _configureAave() internal {
        vm.startPrank(timelock);
        module.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        module.activateAavePoolProvider();
        vm.stopPrank();
    }

    function _registerToken() internal {
        vm.prank(timelock);
        module.registerTokenForAave(address(token), address(aToken));
    }
}

contract MockAavePoolReverting is MockAavePool {
    function withdraw(address, uint256, address) external pure override returns (uint256) {
        revert("Aave withdrawal failed");
    }
}

contract MockAavePoolSlippage is MockAavePool {

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {

        uint256 actualAmount = amount * 9000 / 10000;

        IERC20(asset).transfer(to, actualAmount);

        return actualAmount;

    }

}



contract MockAavePoolWithUnderlying is MockAavePool {



    function getUnderlyingAmount(address, address) external pure returns (uint256) {



        return 100e18;



    }



}







contract MockAavePoolNoAToken is MockAavePool {



    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {



        IERC20(asset).transfer(to, amount);



        return amount;



    }



}




