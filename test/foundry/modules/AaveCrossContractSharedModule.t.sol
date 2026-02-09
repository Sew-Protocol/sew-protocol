// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/EscrowableERC20.sol";
import "../../../contracts/modules/AaveYieldGenerationModule.sol";
import "../../../contracts/mocks/MockAavePool.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";

/**
 * @title AaveCrossContractSharedModule
 * @notice Validates that EscrowVault and EscrowableERC20 can share the same Aave module without cross-contamination.
 */
contract AaveCrossContractSharedModule is Test {
    EscrowVault public vault;
    EscrowableERC20 public escrowERC20;
    AaveYieldGenerationModule public aaveModule;
    YieldOps public yieldOps;
    ModuleSnapshotRegistry public mm;
    ERC20Mock public token;
    MockAavePool public pool;
    MockPoolAddressesProvider public provider;
    MockAToken public aToken;
    MockAToken public aERC20;

    address public owner = address(this);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);

    function setUp() public {
        token = new ERC20Mock("Token", "TKN", owner, 1000e18);
        pool = new MockAavePool();
        aToken = new MockAToken(address(token), "aTKN", "aTKN");
        aToken.setPool(address(pool));
        pool.setAToken(address(token), address(aToken));
        provider = new MockPoolAddressesProvider(address(pool));

        aaveModule = new AaveYieldGenerationModule(owner);
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), owner);
        
        vm.warp(100);

        // 1. Provider Queue
        aaveModule.queueAavePoolProvider(address(provider));
        vm.warp(100 + 8 days);
        aaveModule.activateAavePoolProvider();
        
        aaveModule.setAaveEnabled(true);
        aaveModule.registerTokenForAave(address(token), address(aToken));

        yieldOps = new YieldOps(owner);
        aaveModule.grantRole(aaveModule.ROLE_YIELD_OPS(), address(yieldOps));
        mm = new ModuleSnapshotRegistry(owner);

        vault = new EscrowVault(0, address(0xFEE), address(yieldOps), address(new DisputeOps(owner)), address(mm));
        escrowERC20 = new EscrowableERC20("EscrowERC20", "E20", 0, address(0xFEE), address(yieldOps), address(new DisputeOps(owner)), address(mm));

        yieldOps.registerEscrowContract(address(vault));
        yieldOps.registerEscrowContract(address(escrowERC20));
        mm.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(escrowERC20));

        // 2. Vault Module Queue
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        vm.warp(100 + 16 days);
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);

        // 3. ERC20 Module Queue
        mm.queueModule(address(escrowERC20), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        vm.warp(100 + 24 days);
        mm.activateModule(address(escrowERC20), BaseEscrow.ModuleType.YIELD_GEN);

        aaveModule.registerEscrowContract(address(vault));
        aaveModule.registerEscrowContract(address(escrowERC20));

        aERC20 = new MockAToken(address(escrowERC20), "aE20", "aE20");
        aERC20.setPool(address(pool));
        pool.setAToken(address(escrowERC20), address(aERC20));
        aaveModule.registerTokenForAave(address(escrowERC20), address(aERC20));

        CreateOps co = new CreateOps(owner);
        co.grantRole(co.ROLE_TIMELOCK(), owner);
        co.registerEscrowContract(address(vault));
        co.registerEscrowContract(address(escrowERC20));
        vault.setCreateOps(address(co));
        escrowERC20.setCreateOps(address(co));

        DefaultResolutionModule rm = new DefaultResolutionModule(owner, address(0xDEAD));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.setResolutionModule(address(rm));
        escrowERC20.grantRole(escrowERC20.ROLE_ADMIN_CONTRACT(), owner);
        escrowERC20.setResolutionModule(address(rm));
    }

    function test_simultaneous_vault_and_erc20_positions() public {
        uint256 amount = 100e18;
        
        // Transfer tokens to buyer from test contract (deployer)
        escrowERC20.transfer(buyer, amount);

        vm.startPrank(buyer);
        token.mint(buyer, amount);
        token.approve(address(vault), amount);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        uint256 vaultWid = vault.createEscrow(address(token), seller, amount, settings);
        vm.stopPrank();

        vm.startPrank(buyer);
        escrowERC20.approve(address(escrowERC20), amount);
        uint256 e20Wid = escrowERC20.createEscrow(address(escrowERC20), seller, amount, settings);
        vm.stopPrank();

        assertEq(aaveModule.escrowScaledBalance(address(vault), vaultWid), amount);
        assertEq(aaveModule.escrowScaledBalance(address(escrowERC20), e20Wid), amount);

        vm.prank(buyer);
        vault.releaseEscrowTransfer(vaultWid);
        
        vm.prank(buyer);
        escrowERC20.releaseEscrowTransfer(e20Wid);

        assertEq(aaveModule.escrowScaledBalance(address(vault), vaultWid), 0);
        assertEq(aaveModule.escrowScaledBalance(address(escrowERC20), e20Wid), 0);
        
        assertEq(token.balanceOf(seller), amount);
        assertEq(escrowERC20.balanceOf(seller), amount);
    }
}