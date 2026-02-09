// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/mocks/MockAavePool.sol";
import "../../../contracts/modules/AaveYieldGenerationModule.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";

/**
 * @title YieldAccountingTest
 * @notice Validates precise yield accounting equations using mocks
 * @dev Checks:
 *      1. Refund: escrow amount + yield = returned to buyer + protocol fees
 *      2. Release: escrow amount + yield = released to seller + yield to buyer + protocol fees
 */
contract YieldAccountingTest is Test {
    EscrowVault internal vault;
    ERC20Mock internal token;
    MockAavePool internal pool;
    MockAToken internal aToken;
    MockPoolAddressesProvider internal provider;
    AaveYieldGenerationModule internal aaveModule;
    DefaultYieldDistributionModule internal yieldDistModule;
    
    ModuleSnapshotRegistry internal mm;
    YieldOps internal yieldOps;
    DisputeOps internal disputeOps;
    CreateOps internal createOps;
    SettlementOps internal settlementOps;
    BondCollector internal bondCollector;

    address internal sender = address(0x1);
    address internal recipient = address(0x2);
    address internal feeAddress = address(0xFEE);

    uint256 internal constant ESCROW_AMOUNT = 1000 ether;
    uint256 internal constant YIELD_AMOUNT = 50 ether;
    uint256 internal constant ESCROW_FEE_BPS = 100; // 1%
    uint256 internal constant PROTOCOL_YIELD_FEE_BPS = 2000; // 20%

    function setUp() public {
        // Setup Mocks
        token = new ERC20Mock("Mock", "MCK", address(this), 1_000_000 ether);
        pool = new MockAavePool();
        aToken = new MockAToken(address(token), "aMock", "aMCK");
        aToken.setPool(address(pool));
        pool.setAToken(address(token), address(aToken));
        provider = new MockPoolAddressesProvider(address(pool));

        // Setup Modules
        aaveModule = new AaveYieldGenerationModule(address(this));
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), address(this));
        aaveModule.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 8 days);
        aaveModule.activateAavePoolProvider();
        aaveModule.setAaveEnabled(true);
        aaveModule.registerTokenForAave(address(token), address(aToken));

        yieldDistModule = new DefaultYieldDistributionModule();

        // Setup Core
        yieldOps = new YieldOps(address(this));
        aaveModule.grantRole(aaveModule.ROLE_YIELD_OPS(), address(yieldOps));
        disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));
        
        vault = new EscrowVault(ESCROW_FEE_BPS, feeAddress, address(yieldOps), address(disputeOps), address(mm));
        
        // Register vault with Aave module
        aaveModule.registerEscrowContract(address(vault));
        
        // Wiring
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

        vault.grantRole(vault.ROLE_TIMELOCK(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        
        // Grant admin role for setting fees
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setYieldProtocolFeeBps(PROTOCOL_YIELD_FEE_BPS);

        // Queue and Activate Modules
        vm.startPrank(address(this));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST, address(yieldDistModule));
        vm.warp(block.timestamp + 10 days);
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);
        vm.stopPrank();

        // Fund Sender and Pool
        token.mint(sender, ESCROW_AMOUNT * 2);
        token.mint(address(pool), YIELD_AMOUNT * 10); // Fund pool to pay yield
    }

    function test_YieldAccounting_Refund() public {
        // 1. Create Escrow
        vm.startPrank(sender);
        token.approve(address(vault), ESCROW_AMOUNT);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = vault.createEscrow(address(token), recipient, ESCROW_AMOUNT, settings);
        vm.stopPrank();

        // 2. Simulate Yield
        // Simulate 5 blocks of yield (5%)
        pool.simulateYield(address(token), 5);

        // 3. Record balances before refund
        uint256 senderBalanceBefore = token.balanceOf(sender);
        uint256 feeAddressBalanceBefore = token.balanceOf(feeAddress);
        uint256 poolBalanceBefore = token.balanceOf(address(pool));

        // 4. Cancel (Refund)
        vm.prank(sender);
        vault.senderCancel(workflowId); // Puts into AGREE_TO_CANCEL
        vm.prank(recipient);
        vault.recipientCancel(workflowId); // Confirms and executes

        // 5. Verify Equation
        uint256 senderBalanceAfter = token.balanceOf(sender);
        uint256 feeAddressBalanceAfter = token.balanceOf(feeAddress);
        uint256 poolBalanceAfter = token.balanceOf(address(pool));

        uint256 senderReceived = senderBalanceAfter - senderBalanceBefore;
        uint256 protocolYieldFee = feeAddressBalanceAfter - feeAddressBalanceBefore;
        uint256 withdrawnFromPool = poolBalanceBefore - poolBalanceAfter;

        console.log("Withdrawn From Pool (Principal + Yield):", withdrawnFromPool);
        console.log("Sender Received:", senderReceived);
        console.log("Protocol Fee:", protocolYieldFee);

        // Invariant: Total Out (Sender + Fees) == Total In (Withdrawn from Pool)
        // Note: The vault itself holds no funds for this escrow after withdrawal.
        assertEq(senderReceived + protocolYieldFee, withdrawnFromPool, "Yield accounting mismatch on refund");
        
        // Sanity check: ensure we actually got yield
        uint256 fee = (ESCROW_AMOUNT * ESCROW_FEE_BPS) / 10000;
        uint256 principal = ESCROW_AMOUNT - fee;
        assertGt(withdrawnFromPool, principal, "Should have generated yield");
    }

    function test_YieldAccounting_Release() public {
        // 1. Create Escrow
        vm.startPrank(sender);
        token.approve(address(vault), ESCROW_AMOUNT);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER, // Yield goes to buyer (sender)
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = vault.createEscrow(address(token), recipient, ESCROW_AMOUNT, settings);
        vm.stopPrank();

        // 2. Simulate Yield
        // Simulate 5 blocks of yield (5%)
        pool.simulateYield(address(token), 5);

        // 3. Record balances
        uint256 senderBalanceBefore = token.balanceOf(sender);
        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        uint256 feeAddressBalanceBefore = token.balanceOf(feeAddress);
        uint256 poolBalanceBefore = token.balanceOf(address(pool));

        // 4. Release
        vm.prank(sender);
        vault.releaseEscrowTransfer(workflowId);

        // 5. Verify Equation
        uint256 senderBalanceAfter = token.balanceOf(sender);
        uint256 recipientBalanceAfter = token.balanceOf(recipient);
        uint256 feeAddressBalanceAfter = token.balanceOf(feeAddress);
        uint256 poolBalanceAfter = token.balanceOf(address(pool));

        uint256 senderReceived = senderBalanceAfter - senderBalanceBefore;
        uint256 recipientReceived = recipientBalanceAfter - recipientBalanceBefore;
        uint256 protocolYieldFee = feeAddressBalanceAfter - feeAddressBalanceBefore;
        uint256 withdrawnFromPool = poolBalanceBefore - poolBalanceAfter;

        console.log("Withdrawn From Pool:", withdrawnFromPool);
        console.log("Sender Received (Yield):", senderReceived);
        console.log("Recipient Received (Principal):", recipientReceived);
        console.log("Protocol Fee:", protocolYieldFee);

        uint256 totalOut = senderReceived + recipientReceived + protocolYieldFee;
        
        // Invariant: Total Out (Recipient + Sender + Fees) == Total In (Withdrawn from Pool)
        assertEq(totalOut, withdrawnFromPool, "Yield accounting mismatch on release");
        
        // Sanity check: Recipient should get exactly the principal
        uint256 fee = (ESCROW_AMOUNT * ESCROW_FEE_BPS) / 10000;
        uint256 principal = ESCROW_AMOUNT - fee;
        assertEq(recipientReceived, principal, "Recipient should get full principal");
    }
}