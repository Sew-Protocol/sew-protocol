// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol';
import 'contracts/core/BaseEscrow.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/MockAavePool.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/ops/YieldOps.sol';
import 'contracts/core/ModuleSnapshotRegistry.sol';
import 'contracts/core/EscrowCreationPolicy.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/types/YieldPresets.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @notice Escrow-level end-to-end: EscrowVault ↔ AaveYieldModule.
/// @dev Regression for the deposit-funding model: the escrow only approves the
///      module (pull model), and the module must pull the requested amount.
contract AaveEscrowE2ETest is Test {
    EscrowVault internal vault;
    AaveYieldModule internal aaveModule;
    MockAavePool internal pool;
    MockAToken internal aToken;
    ERC20Mock internal token;
    YieldOps internal yieldOps;
    ModuleSnapshotRegistry internal registry;
    EscrowCreationPolicy internal policy;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        token = new ERC20Mock('Token', 'TKN', address(this), 0);
        aToken = new MockAToken(address(token), 'aTKN', 'aTKN');
        pool = new MockAavePool();
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));

        aaveModule = new AaveYieldModule(address(pool));
        aaveModule.configureToken(address(token), address(aToken));

        yieldOps = new YieldOps(address(this));
        registry = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));

        vault = new EscrowVault(0, FEE, address(yieldOps), address(registry));
        aaveModule.approveEscrow(address(vault));
        yieldOps.registerEscrowContract(address(vault));
        registry.registerEscrowContract(address(vault));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreationPolicy(address(policy));

        // Make the Aave module the default YIELD_GEN module for the vault.
        registry.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);

        token.mint(BUYER, 1_000_000e18);
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
    }

    function _settings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    function test_escrowLevel_aave_deposit_then_cancel_unwinds() public {
        uint256 buyerBalBefore = token.balanceOf(BUYER);

        vm.prank(BUYER);
        uint256 wf = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());

        // Deposit recorded; escrow pulled the amount from the buyer and the
        // module holds the Aave position.
        assertEq(vault.v25YieldModules(wf), address(aaveModule), 'yield module recorded');
        assertEq(vault.v25YieldPrincipals(wf), AMOUNT, 'yield principal recorded');
        assertGt(aToken.balanceOf(address(aaveModule)), 0, 'module holds aTokens');
        assertEq(token.balanceOf(address(vault)), 0, 'escrow forwarded the full amount to yield');
        assertEq(buyerBalBefore - token.balanceOf(BUYER), AMOUNT, 'buyer funded exactly AMOUNT');

        // Simulate yield, then mutually cancel: sender (TO_SENDER) receives principal + yield.
        pool.simulateYield(address(token), 10);

        vm.prank(BUYER);
        vault.senderCancel(wf);
        vm.prank(SELLER);
        vault.recipientCancel(wf);

        assertEq(vault.v25YieldModules(wf), address(0), 'position unwound');
        uint256 claimable = vault.claimableBalances(wf, BUYER);
        assertGt(claimable, AMOUNT, 'sender claimable exceeds principal (yield TO_SENDER)');

        vm.prank(BUYER);
        uint256 got = vault.withdrawEscrow(wf);
        assertEq(got, claimable, 'withdrawn equals claimable');
        assertEq(token.balanceOf(BUYER), buyerBalBefore - AMOUNT + claimable, 'buyer net position');
    }
}
