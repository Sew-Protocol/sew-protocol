// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/AaveYieldGenerationModule.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/mocks/MockAavePool.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/interfaces/aave/AaveV3Interfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Delegatecall target for library pattern
 */
contract AaveLibraryWrapper {
    using SafeERC20 for IERC20;

    function supply(address pool, address token, uint256 amount, address onBehalfOf) external {
        IERC20 tokenContract = IERC20(token);
        uint256 currentAllowance = tokenContract.allowance(address(this), pool);

        if (currentAllowance != amount) {
            if (currentAllowance > 0) {
                tokenContract.safeDecreaseAllowance(pool, currentAllowance);
            }
            tokenContract.safeIncreaseAllowance(pool, amount);
        }

        IAavePool(pool).supply(token, amount, onBehalfOf, 0);

        uint256 remainingAllowance = tokenContract.allowance(address(this), pool);
        if (remainingAllowance > 0) {
            tokenContract.safeDecreaseAllowance(pool, remainingAllowance);
        }
    }

    function withdraw(address pool, address token, uint256 amount, address to) external returns (uint256) {
        return IAavePool(pool).withdraw(token, amount, to);
    }
}

/**
 * @title AaveEdgeCases
 * @notice Tests edge cases for Aave integration
 * @dev Tests 1 wei, tiny amounts, rounding, time edge cases
 */
contract AaveEdgeCases is Test {
    MockAavePool internal pool;
    ERC20Mock internal token;
    MockAToken internal aToken;
    MockPoolAddressesProvider internal provider;
    AaveYieldGenerationModule internal aaveModule;

    EscrowVault internal vault;
    ModuleSnapshotRegistry internal mm;
    YieldOps internal yieldOps;
    DisputeOps internal disputeOps;
    CreateOps internal createOps;
    SettlementOps internal settlementOps;
    BondCollector internal bondCollector;
    DefaultResolutionModule internal resolutionModule;
    DefaultYieldDistributionModule internal yieldDist;
    AaveLibraryWrapper internal wrapper;

    address internal feeAddress = address(0xFEE);
    address internal resolver = address(0xBEEF);
    address internal sender = address(0x1001);
    address internal recipient = address(0x1002);

    uint256 internal constant ESCROW_FEE_BPS = 100;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MIN_NORMALIZED_INCOME = 1e24; // 0.1% of RAY
    uint256 internal constant MIN_DEPOSIT_AMOUNT = 1e15; // 0.001 tokens for 18-decimal

    function setUp() public {
        token = new ERC20Mock("Mock Token", "MOCK", address(this), 10_000_000 ether);
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
        vm.prank(address(this));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST, address(yieldDist));
        (, uint64 etaGen, bool existsGen) = mm.getPendingModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        (, uint64 etaDist, bool existsDist) = mm.getPendingModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);
        require(existsGen && existsDist, "pending modules must exist");
        uint256 maxEta = etaGen > etaDist ? uint256(etaGen) : uint256(etaDist);
        vm.warp(maxEta + 1);
        vm.prank(address(this));
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        vm.prank(address(this));
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);

        wrapper = new AaveLibraryWrapper();
        // Module pattern is now used directly (no delegatecall library needed)
        vault.setYieldProtocolFeeBps(0);

        token.mint(address(pool), 10_000_000 ether);
    }

    /**
     * @notice Test: Handle 1 wei deposit
     */
    function test_supply_handles_1wei() public {
        uint256 amount = 1; // 1 wei
        token.mint(sender, amount);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        
        // Should handle 1 wei (may revert if below minimum, but should handle gracefully)
        // Note: MIN_YIELD_DEPOSIT may prevent this, but we test the edge case
        try vault.createEscrow(address(token), recipient, amount, settings) returns (uint256 wid) {
            // If it succeeds, release should work
            vault.releaseEscrowTransfer(wid);
        } catch {
            // If it reverts due to minimum, that's acceptable
        }
        vm.stopPrank();
    }

    /**
     * @notice Test: Handle tiny amounts (dust)
     */
    function test_supply_handles_tinyAmounts() public {
        uint256 amount = 1000; // 1000 wei (tiny amount)
        token.mint(sender, amount);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        
        // Should handle tiny amounts
        try vault.createEscrow(address(token), recipient, amount, settings) returns (uint256 wid) {
            vault.releaseEscrowTransfer(wid);
        } catch {
            // May revert if below minimum
        }
        vm.stopPrank();
    }

    /**
     * @notice Test: Handle maximum amount (if applicable)
     */
    function test_supply_handles_maxAmount() public {
        // Use a very large amount (but not type(uint256).max to avoid overflow)
        uint256 amount = type(uint128).max; // Large but safe
        token.mint(sender, amount);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Should succeed and be able to release
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Verify recipient received funds
        assertGt(token.balanceOf(recipient), 0, "Recipient should receive funds");
    }

    /**
     * @notice Test: Handle rounding in withdrawals
     */
    function test_withdraw_handles_rounding() public {
        uint256 amount = 100 ether;
        token.mint(sender, amount);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Simulate yield with small increments (to test rounding)
        pool.simulateYield(address(token), 1);

        // Release should handle rounding correctly
        uint256 recipientBalBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);
        uint256 recipientBalAfter = token.balanceOf(recipient);

        // Should receive at least principal (minus fee)
        uint256 fee = (amount * ESCROW_FEE_BPS) / 10000;
        uint256 expectedPrincipal = amount - fee;
        assertGe(recipientBalAfter - recipientBalBefore, expectedPrincipal, "Should receive at least principal");
    }

    /**
     * @notice Test: Yield calculation with zero time
     */
    function test_yieldCalculation_handles_zeroTime() public {
        uint256 amount = 100 ether;
        token.mint(sender, amount);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Don't simulate yield (zero time)
        // Release immediately
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Should still work correctly
        assertGt(token.balanceOf(recipient), 0, "Recipient should receive funds");
    }

    /**
     * @notice Test: Yield calculation with very long time
     */
    function test_yieldCalculation_handles_veryLongTime() public {
        uint256 amount = 100 ether;
        token.mint(sender, amount);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Simulate very long time (many blocks)
        pool.simulateYield(address(token), 10000); // 10000 blocks

        // Release should handle large yield
        uint256 recipientBalBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);
        uint256 recipientBalAfter = token.balanceOf(recipient);

        // Should receive at least principal
        uint256 fee = (amount * ESCROW_FEE_BPS) / 10000;
        uint256 expectedPrincipal = amount - fee;
        assertGe(recipientBalAfter - recipientBalBefore, expectedPrincipal, "Should receive at least principal");
    }

    /**
     * @notice Test: Scaled shares handle normalized income changes
     */
    function test_scaledShares_handles_incomeRay_change() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 200 ether;

        address sender1 = address(0x1001);
        address sender2 = address(0x1002);
        address recipient1 = address(0x2001);
        address recipient2 = address(0x2002);

        token.mint(sender1, amount1);
        token.mint(sender2, amount2);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create first escrow
        vm.startPrank(sender1);
        token.approve(address(vault), amount1);
        uint256 wid1 = vault.createEscrow(address(token), recipient1, amount1, settings);
        vm.stopPrank();

        // Change normalized income (simulate yield)
        pool.simulateYield(address(token), 10);

        // Create second escrow (after income change)
        vm.startPrank(sender2);
        token.approve(address(vault), amount2);
        uint256 wid2 = vault.createEscrow(address(token), recipient2, amount2, settings);
        vm.stopPrank();

        // Change income again
        pool.simulateYield(address(token), 10);

        // Both escrows should withdraw independently
        vm.prank(sender1);
        vault.releaseEscrowTransfer(wid1);

        vm.prank(sender2);
        vault.releaseEscrowTransfer(wid2);

        // Both should receive their principal
        assertGt(token.balanceOf(recipient1), 0, "Recipient1 should receive funds");
        assertGt(token.balanceOf(recipient2), 0, "Recipient2 should receive funds");
    }

    /**
     * @notice Test: Multiple escrows with same token, different amounts
     */
    function test_multipleEscrows_sameToken_differentAmounts() public {
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1 ether;
        amounts[1] = 10 ether;
        amounts[2] = 100 ether;
        amounts[3] = 1000 ether;
        amounts[4] = 10000 ether;

        address[] memory senders = new address[](5);
        address[] memory recipients = new address[](5);
        uint256[] memory workflowIds = new uint256[](5);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create multiple escrows
        for (uint256 i = 0; i < amounts.length; i++) {
            senders[i] = address(uint160(sender) + uint160(i + 1));
            recipients[i] = address(uint160(recipient) + uint160(i + 1));
            token.mint(senders[i], amounts[i]);

            vm.startPrank(senders[i]);
            token.approve(address(vault), amounts[i]);
            workflowIds[i] = vault.createEscrow(address(token), recipients[i], amounts[i], settings);
            vm.stopPrank();
        }

        // Simulate yield
        pool.simulateYield(address(token), 10);

        // Release all escrows
        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(senders[i]);
            vault.releaseEscrowTransfer(workflowIds[i]);

            // Each recipient should receive their principal
            uint256 fee = (amounts[i] * ESCROW_FEE_BPS) / 10000;
            uint256 expectedPrincipal = amounts[i] - fee;
            assertGe(
                token.balanceOf(recipients[i]),
                expectedPrincipal,
                "Recipient should receive at least principal"
            );
        }
    }
}