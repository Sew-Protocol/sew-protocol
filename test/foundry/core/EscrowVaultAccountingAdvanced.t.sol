// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/core/BondCollector.sol';

contract EscrowVaultAccountingAdvancedTest is Test {
    EscrowVault public vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public mm;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    DefaultResolutionModule public resolutionModule;
    
    ERC20Mock public token;

    address public feeAddress1 = address(0xFE1);
    address public feeAddress2 = address(0xFE2);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public resolver = address(0x1234);

    uint256 constant INITIAL_FEE_BPS = 100; // 1%

    function setUp() public {
        token = new ERC20Mock("Token", "TKN", address(this), 1000000e18);

        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));
        createOps = new CreateOps(address(this));
        settlementOps = new SettlementOps(address(this));
        bondCollector = new BondCollector(address(this));
        resolutionModule = new DefaultResolutionModule(address(this), resolver);

        vault = new EscrowVault(INITIAL_FEE_BPS, feeAddress1, address(yieldOps), address(disputeOps), address(mm));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));

        token.transfer(buyer, 500000e18);
    }

    function test_fee_change_mid_escrow() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 1000e18;

        // Create escrow 1 with 1% fee
        vm.startPrank(buyer);
        token.approve(address(vault), amount1 + amount2);
        vault.createEscrow(address(token), seller, amount1, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        // Check fee accumulation
        uint256 expectedFee1 = amount1 * 100 / 10000;
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee1);

        // Change fee to 2%
        vault.setEscrowFeeBps(200);

        // Create escrow 2 with 2% fee
        vm.startPrank(buyer);
        vault.createEscrow(address(token), seller, amount2, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        // Check fee accumulation
        uint256 expectedFee2 = amount2 * 200 / 10000;
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee1 + expectedFee2);

        // Verify escrow 1 principal is still based on 1% fee
        (uint256 principal, , , ) = vault.getAccountingBreakdown(address(token));
        // Total principal = (amount1 - fee1) + (amount2 - fee2)
        uint256 expectedTotalPrincipal = (amount1 - expectedFee1) + (amount2 - expectedFee2);
        assertEq(principal, expectedTotalPrincipal);
    }

    function test_fee_recipient_change() public {
        uint256 amount = 1000e18;
        uint256 expectedFee = amount * 100 / 10000;

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        // Change fee recipient
        vault.setFeeRecipient(feeAddress2);

        // Withdraw fees (should go to new recipient)
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), address(this));
        vault.withdrawFees(address(token));

        assertEq(token.balanceOf(feeAddress1), 0);
        assertEq(token.balanceOf(feeAddress2), expectedFee);
    }

    function test_self_funding_fee_recipient() public {
        // Fee recipient is also the buyer
        vault.setFeeRecipient(buyer);
        
        uint256 amount = 1000e18;
        uint256 fee = amount * 100 / 10000;

        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();

        // Withdraw fees
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), address(this));
        vault.withdrawFees(address(token));

        // Buyer should have received the fee back
        // Initial balance - amount + fee
        assertEq(token.balanceOf(buyer), 500000e18 - amount + fee);
    }
}
