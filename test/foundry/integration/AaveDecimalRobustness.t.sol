// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/EscrowVaultAnalytics.sol';
import '../../../contracts/modules/AaveYieldGenerationModule.sol';
import '../../../contracts/mocks/MockAavePool.sol';
import '../mocks/ERC20LowDecimalMock.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/modules/DefaultYieldDistributionModule.sol';

/**
 * @title AaveDecimalRobustness
 * @notice Tests Aave integration with low-decimal tokens (6 decimals like USDC/USDT).
 */
contract AaveDecimalRobustness is Test {
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
    ERC20LowDecimalMock public usdc;
    MockAToken public aUsdc;

    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public feeAddress = address(0xFEE);
    uint256 constant ESCROW_FEE_BPS = 100; // 1%

    function setUp() public {
        usdc = new ERC20LowDecimalMock("USD Coin", "USDC", 6, address(this), 0);
        pool = new MockAavePool();

        aUsdc = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        aUsdc.setPool(address(pool));
        pool.setAToken(address(usdc), address(aUsdc));
        provider = new MockPoolAddressesProvider(address(pool));

        aaveModule = new AaveYieldGenerationModule(address(this));
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), address(this));
        aaveModule.queueAavePoolProvider(address(provider));
        (, uint64 etaProvider, ) = aaveModule.getPendingAavePoolProvider();
        vm.warp(uint256(etaProvider) + 1);
        aaveModule.activateAavePoolProvider();
        aaveModule.setAaveEnabled(true);
        aaveModule.registerTokenForAave(address(usdc), address(aUsdc));

        yieldOps = new YieldOps(address(this));
        aaveModule.grantRole(aaveModule.ROLE_YIELD_OPS(), address(yieldOps));
        disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));

        vault = new EscrowVault(ESCROW_FEE_BPS, feeAddress, address(yieldOps), address(disputeOps), address(mm));
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

        resolutionModule = new DefaultResolutionModule(address(this), address(0xDEAD));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setResolutionModule(address(resolutionModule));

        yieldDist = new DefaultYieldDistributionModule();
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        vm.warp(block.timestamp + 7 days + 1);
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);

        usdc.mint(buyer, 1000_000_000);
    }

    function test_6Decimal_Accounting() public {
        uint256 amount = 100_000_000; // 100 USDC
        uint256 fee = (amount * ESCROW_FEE_BPS) / 10000;
        uint256 expectedPrincipal = amount - fee;

        vm.startPrank(buyer);
        usdc.approve(address(vault), amount);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        uint256 wid = vault.createEscrow(address(usdc), seller, amount, settings);
        vm.stopPrank();

        assertEq(vault.totalHeldInEscrowPerToken(address(usdc)), expectedPrincipal);
        assertEq(vault.totalFeesPerToken(address(usdc)), fee);
        assertEq(aaveModule.escrowScaledBalance(address(vault), wid), expectedPrincipal);
    }

    function test_6Decimal_YieldAndDust() public {
        uint256 amount = 100_000_000; // 100 USDC
        vm.startPrank(buyer);
        usdc.approve(address(vault), amount);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        vault.createEscrow(address(usdc), seller, amount, settings);
        vm.stopPrank();

        // Release escrow - without extra yield, no dust
        vm.prank(buyer);
        vault.releaseEscrowTransfer(0);

        assertEq(aaveModule.protocolDust(address(usdc)), 0);
    }

    function test_6Decimal_EmergencyUnwind() public {
        uint256 amount = 100_000_000; // 100 USDC
        uint256 principal = 99_000_000;
        vm.startPrank(buyer);
        usdc.approve(address(vault), amount);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        uint256 wid = vault.createEscrow(address(usdc), seller, amount, settings);
        vm.stopPrank();

        // Emergency Unwind
        aaveModule.grantRole(aaveModule.ROLE_GUARDIAN(), address(this));
        
        // Verify balance before
        assertEq(usdc.balanceOf(address(vault)), amount - principal); 

        aaveModule.emergencyUnwind(address(usdc), wid, address(vault));

        // After emergency unwind, funds are back in the Vault
        // The Module state is cleared, so the Vault is now 're-collateralized'
        assertEq(usdc.balanceOf(address(vault)), amount);
        
        // The User (Buyer) should still be able to release the escrow
        // Even though the module was unwound, the Vault now holds the tokens locally
        vm.prank(buyer);
        vault.releaseEscrowTransfer(wid);
        
        assertEq(usdc.balanceOf(seller), principal);
    }
}