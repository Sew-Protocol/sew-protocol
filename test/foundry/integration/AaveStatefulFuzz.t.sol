// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./AaveHandler.t.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/ModuleManagementContract.sol";
import "../../../contracts/modules/AaveYieldGenerationModule.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/mocks/MockAavePool.sol";
import "../../../contracts/YieldOps.sol";
import "../../../contracts/DisputeOps.sol";
import "../../../contracts/CreateOps.sol";
import "../../../contracts/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";

contract AaveStatefulFuzz is Test {
    AaveHandler public handler;
    EscrowVault public vault;
    AaveYieldGenerationModule public aaveModule;
    MockAavePool public aavePool;
    ERC20Mock public token;
    ModuleManagementContract public mm;
    
    function setUp() public {
        token = new ERC20Mock("Mock Token", "MOCK", address(this), 0);
        aavePool = new MockAavePool();
        
        MockAToken aToken = new MockAToken(address(token), "aMock", "aMOCK");
        aToken.setPool(address(aavePool));
        aavePool.setAToken(address(token), address(aToken));
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(aavePool));
        
        aaveModule = new AaveYieldGenerationModule(address(this));
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), address(this));
        aaveModule.queueAavePoolProvider(address(provider));
        
        YieldOps yieldOps = new YieldOps(address(this));
        DisputeOps disputeOps = new DisputeOps(address(this));
        mm = new ModuleManagementContract(address(this));
        
        vault = new EscrowVault(100, address(0xFEE), address(yieldOps), address(disputeOps), address(mm));
        
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));
        
        CreateOps createOps = new CreateOps(address(this));
        createOps.grantRole(createOps.ROLE_TIMELOCK(), address(this));
        createOps.registerEscrowContract(address(vault));
        vault.setCreateOps(address(createOps));
        
        SettlementOps settlementOps = new SettlementOps(address(this));
        settlementOps.registerEscrowContract(address(vault));
        vault.setSettlementOps(address(settlementOps));
        
        DefaultYieldDistributionModule yieldDist = new DefaultYieldDistributionModule();
        vm.prank(address(this));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        vm.prank(address(this));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST, address(yieldDist));
        
        // One big warp for all
        vm.warp(block.timestamp + 15 days);
        
        aaveModule.activateAavePoolProvider();
        aaveModule.setAaveEnabled(true);
        aaveModule.registerTokenForAave(address(token), address(aToken));
        
        // Fund pool to cover yield payments
        token.mint(address(aavePool), 1_000_000_000 ether);
        
        vm.prank(address(this));
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        vm.prank(address(this));
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);
        
        handler = new AaveHandler(vault, aaveModule, aavePool, token);
        
        targetContract(address(handler));
    }
    
    function invariant_conservation_of_funds() public view {
        uint256 totalEscrowed = vault.totalHeldInEscrowPerToken(address(token));
        uint256 totalFees = vault.totalFeesPerToken(address(token));
        uint256 contractBalance = token.balanceOf(address(vault));
        uint256 inAave = aaveModule.getTotalDepositedToAave(address(token));
        uint256 totalClaimable = handler.totalClaimable();
        uint256 dust = aaveModule.protocolDust(address(token));
        uint256 deficit = aaveModule.protocolDeficit(address(token));
        
        // Principal should be balanced: 
        // assets (balance + inAave + dust) = liabilities (escrowed + fees + claimable + deficit)
        uint256 totalAssets = contractBalance + inAave + dust;
        uint256 totalLiabilities = totalEscrowed + totalFees + totalClaimable + deficit;
        
        // Use a small tolerance (50 wei) for cumulative rounding noise in the mock environment
        if (totalAssets > totalLiabilities) {
            assertLe(totalAssets - totalLiabilities, 50, "Assets significantly exceed liabilities");
        } else {
            assertLe(totalLiabilities - totalAssets, 50, "Liabilities significantly exceed assets");
        }
    }
}
