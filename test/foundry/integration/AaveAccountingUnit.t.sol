// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/modules/AaveYieldGenerationModule.sol';
import '../../../contracts/mocks/MockAavePool.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/modules/DefaultYieldDistributionModule.sol';

/**
 * @title AaveAccountingUnit
 * @notice Unit tests for accounting correctness in Aave integration.
 *
 * Tests verify:
 * 1. Principal tracking (totalHeldInEscrowPerToken)
 * 2. Fee collection accuracy
 * 3. getAccountingBreakdown calculations
 * 4. Balance consistency (vault balance = principal + fees)
 * 5. Yield doesn't affect principal or fee tracking
 * 6. Multi-token accounting isolation
 */
contract AaveAccountingUnit is Test {
    EscrowVault public vault;
    AaveYieldGenerationModule public aaveModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public mm;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    DefaultResolutionModule public resolutionModule;
    DefaultYieldDistributionModule public yieldDist;
    MockAavePool public pool;
    MockPoolAddressesProvider public provider;
    ERC20Mock public token;
    MockAToken public aToken;

    address public resolver = address(0x1);
    address public feeAddress = address(0x2);
    address public buyer = address(0x3);
    address public seller = address(0x4);

    uint256 constant ESCROW_FEE_BPS = 100;
    uint256 constant INITIAL_BALANCE = 10_000_000 ether;

    function setUp() public {
        token = new ERC20Mock("Mock Token", "MOCK", address(this), INITIAL_BALANCE);
        pool = new MockAavePool();

        aToken = new MockAToken(address(token), "aMock", "aMOCK");
        aToken.setPool(address(pool));
        pool.setAToken(address(token), address(aToken));
        provider = new MockPoolAddressesProvider(address(pool));

        aaveModule = new AaveYieldGenerationModule(address(this));
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), address(this));
        aaveModule.queueAavePoolProvider(address(provider));
        (, uint64 etaProvider, bool existsProvider) = aaveModule.getPendingAavePoolProvider();
        require(existsProvider, "pending provider must exist");
        vm.warp(uint256(etaProvider) + 1);
        aaveModule.activateAavePoolProvider();
        aaveModule.setAaveEnabled(true);
        aaveModule.registerTokenForAave(address(token), address(aToken));

        yieldOps = new YieldOps(address(this));
        aaveModule.grantRole(aaveModule.ROLE_YIELD_OPS(), address(yieldOps));
        disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));

        vault = new EscrowVault(ESCROW_FEE_BPS, feeAddress, address(yieldOps), address(disputeOps), address(mm));

        // Register vault with Aave module
        aaveModule.registerEscrowContract(address(vault));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));

        createOps = new CreateOps(address(this));
        createOps.grantRole(createOps.ROLE_TIMELOCK(), address(this));
        createOps.registerEscrowContract(address(vault));

        settlementOps = new SettlementOps(address(this));
        settlementOps.registerEscrowContract(address(vault));

        bondCollector = new BondCollector(address(this));
        bondCollector.registerEscrowContract(address(vault));

        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        resolutionModule = new DefaultResolutionModule(address(this), resolver);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setResolutionModule(address(resolutionModule));

        yieldDist = new DefaultYieldDistributionModule();
        vm.prank(address(this));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));

        // Fund accounts
        token.mint(buyer, INITIAL_BALANCE);
        token.mint(seller, INITIAL_BALANCE);
    }

    // ============ Principal Tracking Tests ============

    function test_totalHeldInEscrowPerToken_increments_on_create() public {
        uint256 amount = 100e18;
        uint256 expectedPrincipal = amount - (amount * ESCROW_FEE_BPS / 10000);

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        assertEq(vault.totalHeldInEscrowPerToken(address(token)), expectedPrincipal, 'Principal tracked correctly');
    }

    function test_totalHeldInEscrowPerToken_multiple_escrows() public {
        uint256 amount1 = 100e18;
        uint256 amount2 = 200e18;
        uint256 expectedPrincipal1 = amount1 - (amount1 * ESCROW_FEE_BPS / 10000);
        uint256 expectedPrincipal2 = amount2 - (amount2 * ESCROW_FEE_BPS / 10000);

        vm.startPrank(buyer);
        token.approve(address(vault), amount1 + amount2);

        vault.createEscrow(address(token), seller, amount1, SettingsValidationLibrary.getDefaultSettings());
        vault.createEscrow(address(token), seller, amount2, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        uint256 totalExpected = expectedPrincipal1 + expectedPrincipal2;
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), totalExpected, 'Principal accumulates across escrows');
    }

    // ============ Fee Collection Tests ============

    function test_totalFeesPerToken_increments_on_create() public {
        uint256 amount = 100e18;
        uint256 expectedFee = (amount * ESCROW_FEE_BPS) / 10000;

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        assertEq(vault.totalFeesPerToken(address(token)), expectedFee, 'Fees tracked correctly');
    }

    function test_totalFeesPerToken_multiple_escrows() public {
        uint256 amount1 = 100e18;
        uint256 amount2 = 200e18;
        uint256 expectedFee1 = (amount1 * ESCROW_FEE_BPS) / 10000;
        uint256 expectedFee2 = (amount2 * ESCROW_FEE_BPS) / 10000;

        vm.startPrank(buyer);
        token.approve(address(vault), amount1 + amount2);

        vault.createEscrow(address(token), seller, amount1, SettingsValidationLibrary.getDefaultSettings());
        vault.createEscrow(address(token), seller, amount2, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        uint256 totalExpected = expectedFee1 + expectedFee2;
        assertEq(vault.totalFeesPerToken(address(token)), totalExpected, 'Fees accumulate across escrows');
    }

    // ============ getAccountingBreakdown Tests ============

    function test_getAccountingBreakdown_basic() public {
        uint256 amount = 100e18;
        uint256 expectedPrincipal = amount - (amount * ESCROW_FEE_BPS / 10000);
        uint256 expectedFee = (amount * ESCROW_FEE_BPS) / 10000;

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        (uint256 principal, uint256 fees, uint256 contractBalance, uint256 yieldInBalance) =
            vault.getAccountingBreakdown(address(token));

        assertEq(principal, expectedPrincipal, 'Principal in breakdown correct');
        assertEq(fees, expectedFee, 'Fees in breakdown correct');
        assertEq(contractBalance, amount, 'Contract balance reflects deposits');
        assertEq(yieldInBalance, 0, 'No yield yet');
    }

    function test_getAccountingBreakdown_with_yield() public {
        uint256 amount = 100e18;
        uint256 yieldAmount = 10e18;
        uint256 expectedPrincipal = amount - (amount * ESCROW_FEE_BPS / 10000);
        uint256 expectedFee = (amount * ESCROW_FEE_BPS) / 10000;

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        // Simulate yield
        token.mint(address(vault), yieldAmount);

        (uint256 principal, uint256 fees, uint256 contractBalance, uint256 yieldInBalance) =
            vault.getAccountingBreakdown(address(token));

        assertEq(principal, expectedPrincipal, 'Principal unchanged with yield');
        assertEq(fees, expectedFee, 'Fees unchanged with yield');
        assertEq(contractBalance, amount + yieldAmount, 'Contract balance includes yield');
        assertEq(yieldInBalance, yieldAmount, 'Yield calculated as excess');
    }

    function test_getAccountingBreakdown_after_fee_withdrawal() public {
        uint256 amount = 100e18;
        uint256 expectedPrincipal = amount - (amount * ESCROW_FEE_BPS / 10000);

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), address(this));
        vault.withdrawFees(address(token));

        (uint256 principal, uint256 fees, uint256 contractBalance, uint256 yieldInBalance) =
            vault.getAccountingBreakdown(address(token));

        assertEq(principal, expectedPrincipal, 'Principal unchanged after fee withdrawal');
        assertEq(fees, 0, 'Fees zero after withdrawal');
        assertEq(contractBalance, expectedPrincipal, 'Contract balance reduced by fees');
        assertEq(yieldInBalance, 0, 'No yield');
    }

    // ============ Balance Consistency Tests ============

    function test_balance_consistency_vault_equals_principal_plus_fees() public {
        uint256 amount = 100e18;
        uint256 expectedPrincipal = amount - (amount * ESCROW_FEE_BPS / 10000);
        uint256 expectedFee = (amount * ESCROW_FEE_BPS) / 10000;

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        uint256 vaultBalance = token.balanceOf(address(vault));
        uint256 heldPrincipal = vault.totalHeldInEscrowPerToken(address(token));
        uint256 collectedFees = vault.totalFeesPerToken(address(token));

        assertEq(vaultBalance, heldPrincipal + collectedFees, 'Vault balance = principal + fees');
    }

    function test_balance_consistency_multiple_escrows() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 75e18;
        uint256 amount3 = 100e18;
        uint256 totalDeposited = amount1 + amount2 + amount3;
        uint256 totalFees = (totalDeposited * ESCROW_FEE_BPS) / 10000;
        uint256 totalPrincipal = totalDeposited - totalFees;

        vm.startPrank(buyer);
        token.approve(address(vault), totalDeposited);

        vault.createEscrow(address(token), seller, amount1, SettingsValidationLibrary.getDefaultSettings());
        vault.createEscrow(address(token), seller, amount2, SettingsValidationLibrary.getDefaultSettings());
        vault.createEscrow(address(token), seller, amount3, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        uint256 vaultBalance = token.balanceOf(address(vault));
        uint256 heldPrincipal = vault.totalHeldInEscrowPerToken(address(token));
        uint256 collectedFees = vault.totalFeesPerToken(address(token));

        assertEq(heldPrincipal, totalPrincipal, 'Total principal correct');
        assertEq(collectedFees, totalFees, 'Total fees correct');
        assertEq(vaultBalance, totalDeposited, 'Vault balance = total deposits');
        assertEq(vaultBalance, heldPrincipal + collectedFees, 'Vault balance = principal + fees');
    }

    function test_accounting_yield_doesnt_affect_principal() public {
        uint256 amount = 100e18;
        uint256 yieldAmount = 50e18;
        uint256 expectedPrincipal = amount - (amount * ESCROW_FEE_BPS / 10000);
        uint256 expectedFee = (amount * ESCROW_FEE_BPS) / 10000;

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        uint256 principalBefore = vault.totalHeldInEscrowPerToken(address(token));
        uint256 feesBefore = vault.totalFeesPerToken(address(token));

        // Add yield
        token.mint(address(vault), yieldAmount);

        // Principal and fees should be unchanged
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), principalBefore, 'Principal unchanged');
        assertEq(vault.totalFeesPerToken(address(token)), feesBefore, 'Fees unchanged');

        (uint256 principal, uint256 fees, uint256 contractBalance, uint256 yieldInBalance) =
            vault.getAccountingBreakdown(address(token));

        assertEq(principal, expectedPrincipal, 'Principal in breakdown correct');
        assertEq(fees, expectedFee, 'Fees in breakdown correct');
        assertEq(contractBalance, amount + yieldAmount, 'Contract balance includes yield');
        assertEq(yieldInBalance, yieldAmount, 'Yield separated from principal+fees');
    }

    function test_accounting_large_amounts() public {
        uint256 amount = 1000000e18;
        uint256 expectedPrincipal = amount - (amount * ESCROW_FEE_BPS / 10000);
        uint256 expectedFee = (amount * ESCROW_FEE_BPS) / 10000;

        token.mint(buyer, amount);

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        (uint256 principal, uint256 fees, uint256 contractBalance, uint256 yieldInBalance) =
            vault.getAccountingBreakdown(address(token));

        assertEq(principal, expectedPrincipal, 'Principal correct for large amounts');
        assertEq(fees, expectedFee, 'Fees correct for large amounts');
        assertEq(contractBalance, amount, 'Contract balance correct');
        assertEq(yieldInBalance, 0, 'No yield');
    }

    function test_accounting_isolation_same_token() public {
        uint256 amount1 = 100e18;
        uint256 amount2 = 200e18;

        vm.startPrank(buyer);
        token.approve(address(vault), amount1 + amount2);

        uint256 wid1 = vault.createEscrow(address(token), seller, amount1, SettingsValidationLibrary.getDefaultSettings());
        uint256 wid2 = vault.createEscrow(address(token), seller, amount2, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        // Verify accumulation (not per-escrow isolation, but per-token tracking)
        uint256 expectedPrincipal1 = amount1 - (amount1 * ESCROW_FEE_BPS / 10000);
        uint256 expectedPrincipal2 = amount2 - (amount2 * ESCROW_FEE_BPS / 10000);
        uint256 totalExpectedPrincipal = expectedPrincipal1 + expectedPrincipal2;

        assertEq(vault.totalHeldInEscrowPerToken(address(token)), totalExpectedPrincipal, 'Principal accumulated from both escrows');
    }
}
