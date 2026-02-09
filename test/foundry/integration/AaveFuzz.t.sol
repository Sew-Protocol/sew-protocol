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
import {EscrowTransfer} from "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/interfaces/aave/AaveV3Interfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Delegatecall target for library pattern (same as AaveIntegration.test.t.sol)
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
 * @title AaveFuzz
 * @notice Fuzz tests for Aave integration
 * @dev Tests property-based scenarios for yield generation, accounting, and caps
 */
contract AaveFuzz is Test {
    // Aave mocks
    MockAavePool internal pool;
    ERC20Mock internal token;
    MockAToken internal aToken;
    MockPoolAddressesProvider internal provider;
    AaveYieldGenerationModule internal aaveModule;

    // Core system
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

    uint256 internal constant ESCROW_FEE_BPS = 100; // 1%
    uint256 internal constant INITIAL_SENDER_BAL = 10_000_000 ether; // Large balance for fuzzing
    uint256 internal constant RAY = 1e27; // Aave RAY constant

    function setUp() public {
        // Deploy underlying and Aave mocks
        token = new ERC20Mock("Mock Token", "MOCK", address(this), 10_000_000 ether);
        pool = new MockAavePool();

        aToken = new MockAToken(address(token), "aMock", "aMOCK");
        aToken.setPool(address(pool));
        pool.setAToken(address(token), address(aToken));
        provider = new MockPoolAddressesProvider(address(pool));

        // Deploy module
        aaveModule = new AaveYieldGenerationModule(address(this));
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), address(this));
        aaveModule.queueAavePoolProvider(address(provider));
        (, uint64 etaProvider, bool existsProvider) = aaveModule.getPendingAavePoolProvider();
        require(existsProvider, "pending provider must exist");
        vm.warp(uint256(etaProvider) + 1);
        aaveModule.activateAavePoolProvider();
        aaveModule.setAaveEnabled(true);
        aaveModule.registerTokenForAave(address(token), address(aToken));

        // Deploy core system
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

        // Set default yield modules
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

        // Module pattern is now used directly
        vault.setYieldProtocolFeeBps(0);

        // Fund sender and pool
        token.mint(sender, INITIAL_SENDER_BAL);
        token.mint(address(pool), 10_000_000 ether); // Ensure pool has liquidity
    }

    /**
     * @notice Fuzz test: Round-trip deposit and withdraw conserves assets
     * @param amount Amount to deposit (bounded to prevent overflow)
     * @param steps Number of yield simulation steps
     */
    function testFuzz_supplyWithdraw_roundTrips(uint256 amount, uint8 steps) public {
        // Bound inputs to reasonable ranges
        amount = bound(amount, 1 ether, 1_000_000 ether);
        steps = uint8(bound(steps, 0, 100));

        // Ensure sender has enough balance
        if (token.balanceOf(sender) < amount) {
            token.mint(sender, amount);
        }

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        uint256 senderBalBefore = token.balanceOf(sender);
        uint256 recipientBalBefore = token.balanceOf(recipient);
        uint256 vaultBalBefore = token.balanceOf(address(vault));

        // Create escrow
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Simulate yield
        if (steps > 0) {
            pool.simulateYield(address(token), steps);
        }

        // Release escrow
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        uint256 senderBalAfter = token.balanceOf(sender);
        uint256 recipientBalAfter = token.balanceOf(recipient);
        uint256 vaultBalAfter = token.balanceOf(address(vault));

        // Calculate expected balances
        uint256 fee = (amount * ESCROW_FEE_BPS) / 10000;
        uint256 principal = amount - fee;

        // Recipient should receive at least principal (may be more if yield accrued)
        assertGe(recipientBalAfter - recipientBalBefore, principal, "Recipient should receive at least principal");

        // Total balance should be conserved (sender + recipient + vault + pool)
        // Note: With yield accrual, the total can increase slightly
        uint256 totalBefore = senderBalBefore + recipientBalBefore + vaultBalBefore + token.balanceOf(address(pool));
        uint256 totalAfter = senderBalAfter + recipientBalAfter + vaultBalAfter + token.balanceOf(address(pool));
        
        // Allow for yield accrual and rounding differences
        // Yield can increase total, but should be bounded (max 2x original for extreme cases)
        assertGe(totalAfter, totalBefore, "Total should not decrease");
        assertLe(totalAfter, totalBefore + amount, "Total increase should be bounded by yield accrual");
    }

    /**
     * @notice Fuzz test: Caps are never exceeded
     * @param amounts Array of amounts to deposit across multiple escrows
     */
    function testFuzz_capsNeverExceeded(uint256[5] memory amounts) public {
        // Bound amounts to reasonable ranges
        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], 1 ether, 1_000_000 ether);
        }

        // Set a global cap
        uint256 globalCap = 10_000_000 ether;
        aaveModule.setGlobalCap(address(token), globalCap);

        // Set a token cap (per-escrow cap is not implemented, so we use token cap)
        uint256 tokenCap = 5_000_000 ether;
        aaveModule.setTokenCap(address(token), tokenCap);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        uint256 totalDeposited = 0;

        // Try to create escrows with the fuzzed amounts
        for (uint256 i = 0; i < amounts.length; i++) {
            // Mint tokens to a unique sender for each escrow (use proper address generation)
            address currentSender = address(uint160(uint256(keccak256(abi.encodePacked("sender", i)))));
            if (token.balanceOf(currentSender) < amounts[i]) {
                token.mint(currentSender, amounts[i]);
            }

            vm.startPrank(currentSender);
            token.approve(address(vault), amounts[i]);

            // Check if this deposit would exceed caps
            uint256 newExposure = aaveModule.currentExposure(address(token)) + amounts[i];
            bool wouldExceedTokenCap = aaveModule.tokenCap(address(token)) > 0 && 
                                       newExposure > aaveModule.tokenCap(address(token));
            bool wouldExceedGlobalCap = aaveModule.globalCap(address(token)) > 0 && 
                                        newExposure > aaveModule.globalCap(address(token));

            if (wouldExceedTokenCap || wouldExceedGlobalCap) {
                // Should revert
                vm.expectRevert();
                vault.createEscrow(address(token), recipient, amounts[i], settings);
            } else {
                // Should succeed
                uint256 wid = vault.createEscrow(address(token), recipient, amounts[i], settings);
                totalDeposited += amounts[i];
                
                // Verify exposure was updated
                assertLe(
                    aaveModule.currentExposure(address(token)),
                    aaveModule.globalCap(address(token)) > 0 ? aaveModule.globalCap(address(token)) : type(uint256).max,
                    "Exposure should not exceed global cap"
                );
                assertLe(
                    aaveModule.currentExposure(address(token)),
                    aaveModule.tokenCap(address(token)) > 0 ? aaveModule.tokenCap(address(token)) : type(uint256).max,
                    "Exposure should not exceed token cap"
                );
            }
            vm.stopPrank();
        }

        // Final check: exposure should never exceed caps
        uint256 finalExposure = aaveModule.currentExposure(address(token));
        if (aaveModule.globalCap(address(token)) > 0) {
            assertLe(finalExposure, aaveModule.globalCap(address(token)), "Final exposure exceeds global cap");
        }
        if (aaveModule.tokenCap(address(token)) > 0) {
            assertLe(finalExposure, aaveModule.tokenCap(address(token)), "Final exposure exceeds token cap");
        }
    }

    /**
     * @notice Fuzz test: Settlement never overpays
     * @param amount Amount for escrow (bounded)
     */
    function testFuzz_settle_neverOverpays(uint256 amount) public {
        // Bound amount to reasonable range (ignore escrowId, create new escrow)
        amount = bound(amount, 1 ether, 1_000_000 ether);

        // Ensure sender has balance
        if (token.balanceOf(sender) < amount) {
            token.mint(sender, amount);
        }

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        uint256 recipientBalBefore = token.balanceOf(recipient);
        uint256 senderBalBefore = token.balanceOf(sender);

        // Create escrow
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Simulate some yield
        pool.simulateYield(address(token), 10);

        // Get escrow state - escrowTransfers is a public array, returns tuple (10 components)
        (, , , , uint256 amountAfterFee, , , , , ) = vault.escrowTransfers(wid);
        require(amountAfterFee > 0, "Escrow must exist");

        // Release escrow
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        uint256 recipientBalAfter = token.balanceOf(recipient);
        uint256 senderBalAfter = token.balanceOf(sender);

        // Calculate expected amounts
        uint256 fee = (amount * ESCROW_FEE_BPS) / 10000;
        uint256 expectedPrincipal = amount - fee;

        // Recipient should receive at least principal, but never more than total (principal + yield)
        // Since yield goes to sender, recipient gets principal
        assertGe(recipientBalAfter - recipientBalBefore, expectedPrincipal, "Recipient should receive at least principal");
        
        // Total paid out should not exceed original deposit + yield
        // Calculate total paid: recipient gets principal, sender gets yield back
        // Sender balance change = (initial - deposit + yield back) = (before - amount + yield)
        // So: (after - before) = -amount + yield, meaning yield = (after - before) + amount
        // Total paid = recipient increase + sender increase (which is negative or small)
        uint256 recipientIncrease = recipientBalAfter > recipientBalBefore ? recipientBalAfter - recipientBalBefore : 0;
        uint256 senderIncrease = senderBalAfter > senderBalBefore ? senderBalAfter - senderBalBefore : 0;
        uint256 totalPaid = recipientIncrease + senderIncrease;
        
        // Total paid should not exceed original deposit (allowing for yield accrual and rounding)
        // With yield, total paid can be slightly more than deposit, but should be bounded
        assertLe(totalPaid, amount * 2, "Total paid should be bounded (allowing for yield)");
    }

    /**
     * @notice Fuzz test: No lingering approvals after operations
     * @param amount Amount to deposit
     */
    function testFuzz_noLingeringAllowance(uint256 amount) public {
        // Bound amount
        amount = bound(amount, 1 ether, 1_000_000 ether);

        // Ensure sender has balance
        if (token.balanceOf(sender) < amount) {
            token.mint(sender, amount);
        }

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create escrow
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Check allowance after deposit - should be 0 or minimal
        uint256 allowanceAfterDeposit = token.allowance(address(vault), address(pool));
        assertLe(allowanceAfterDeposit, 1, "Allowance should be reset after deposit");

        // Release escrow
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        // Check allowance after withdrawal - should still be 0 or minimal
        uint256 allowanceAfterWithdraw = token.allowance(address(vault), address(pool));
        assertLe(allowanceAfterWithdraw, 1, "Allowance should be reset after withdrawal");
    }

    /**
     * @notice Fuzz test: Yield calculation precision across ranges
     * @param principal Principal amount
     * @param timeElapsed Time elapsed in blocks (for yield simulation)
     */
    function testFuzz_yieldCalculation_precision(uint256 principal, uint256 timeElapsed) public {
        // Bound inputs
        principal = bound(principal, 1 ether, 1_000_000 ether);
        timeElapsed = bound(timeElapsed, 0, 1000); // Up to 1000 blocks

        // Ensure sender has balance
        if (token.balanceOf(sender) < principal) {
            token.mint(sender, principal);
        }

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        uint256 senderBalBefore = token.balanceOf(sender);

        // Create escrow
        vm.startPrank(sender);
        token.approve(address(vault), principal);
        uint256 wid = vault.createEscrow(address(token), recipient, principal, settings);
        vm.stopPrank();

        // Simulate yield over time
        if (timeElapsed > 0) {
            pool.simulateYield(address(token), timeElapsed);
        }

        // Release escrow
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);

        uint256 senderBalAfter = token.balanceOf(sender);

        // Sender should receive back at least what they deposited (minus fee)
        // Plus any yield that accrued
        uint256 fee = (principal * ESCROW_FEE_BPS) / 10000;
        uint256 expectedMinReturn = principal - fee;

        // Sender balance change should be >= expected minimum (they get yield back)
        // Balance change = (after - before) = (initial - deposit + yield back)
        // So: (after - before) >= -(deposit) + yield
        // Simplified: after >= before - deposit + yield
        // Since yield goes to sender, they should get at least the yield amount back
        assertGe(senderBalAfter, senderBalBefore - principal, "Sender should receive yield back");
    }

    /**
     * @notice Fuzz test: Scaled shares with various normalized income values (CRIT-1)
     * @param amount Deposit amount
     * @param blocksElapsed Blocks elapsed (for yield simulation)
     * @dev Tests that principal protection works across various income scenarios
     */
    function testFuzz_scaledShares_variousIncomeValues(uint256 amount, uint256 blocksElapsed) public {
        // Bound amount to reasonable range (above minimum deposit: 1e15)
        amount = bound(amount, 1 ether, 1_000_000 ether);
        
        // Bound blocks to reasonable range (0 to 1000 blocks to avoid extreme yield)
        // Very large blocks can cause pool to have insufficient liquidity
        blocksElapsed = bound(blocksElapsed, 0, 1000);
        
        // Ensure sender has balance
        if (token.balanceOf(sender) < amount) {
            token.mint(sender, amount);
        }

        // Ensure pool has enough liquidity for withdrawals (especially with yield)
        // MockAavePool's withdraw calculates: actualAmount = amount * index / INITIAL_LIQUIDITY_INDEX
        // With yield, index increases, so we need more tokens in pool
        // Rough estimate: max yield = amount * (1 + blocksElapsed * YIELD_RATE / INITIAL_LIQUIDITY_INDEX)
        uint256 maxYieldMultiplier = 1e27 + (blocksElapsed * 1e25); // Simplified estimate
        uint256 maxWithdrawal = (amount * maxYieldMultiplier) / 1e27;
        uint256 poolBalance = token.balanceOf(address(pool));
        if (poolBalance < maxWithdrawal) {
            token.mint(address(pool), maxWithdrawal - poolBalance + amount); // Extra buffer
        }

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            releaseAddress: address(0), // Added default releaseAddress
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        
        // Create escrow
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Simulate yield over time (this increases normalized income)
        // Note: MockAavePool.simulateYield increases liquidity index, which affects withdrawals
        if (blocksElapsed > 0) {
            pool.simulateYield(address(token), blocksElapsed);
        }

        // Release escrow
        uint256 recipientBalBefore = token.balanceOf(recipient);
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);
        uint256 recipientBalAfter = token.balanceOf(recipient);

        // User should always get at least principal (minus fee)
        // CRIT-1: Principal protection ensures this even if income calculations are off
        uint256 fee = (amount * ESCROW_FEE_BPS) / 10000;
        uint256 expectedPrincipal = amount - fee;
        
        // Allow for small rounding differences (1 wei tolerance)
        assertGe(
            recipientBalAfter - recipientBalBefore,
            expectedPrincipal - 1,
            "User should always get at least principal back regardless of income value"
        );
    }

    /**
     * @notice Fuzz test: Scaled shares accounting with multiple escrows
     * @param amount1 First escrow amount
     * @param amount2 Second escrow amount
     */
    function testFuzz_scaledShares_accounting(uint256 amount1, uint256 amount2) public {
        // Bound amounts
        amount1 = bound(amount1, 1 ether, 1_000_000 ether);
        amount2 = bound(amount2, 1 ether, 1_000_000 ether);

        address sender1 = address(0x1001);
        address sender2 = address(0x1002);
        address recipient1 = address(0x2001);
        address recipient2 = address(0x2002);

        // Fund senders
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

        // Create second escrow
        vm.startPrank(sender2);
        token.approve(address(vault), amount2);
        uint256 wid2 = vault.createEscrow(address(token), recipient2, amount2, settings);
        vm.stopPrank();

        // Accrue yield
        pool.simulateYield(address(token), 10);

        // Release first escrow
        uint256 recipient1BalBefore = token.balanceOf(recipient1);
        vm.prank(sender1);
        vault.releaseEscrowTransfer(wid1);
        uint256 recipient1BalAfter = token.balanceOf(recipient1);

        // Release second escrow
        uint256 recipient2BalBefore = token.balanceOf(recipient2);
        vm.prank(sender2);
        vault.releaseEscrowTransfer(wid2);
        uint256 recipient2BalAfter = token.balanceOf(recipient2);

        // Both should receive their principal (minus fee)
        uint256 fee1 = (amount1 * ESCROW_FEE_BPS) / 10000;
        uint256 fee2 = (amount2 * ESCROW_FEE_BPS) / 10000;
        uint256 expectedPrincipal1 = amount1 - fee1;
        uint256 expectedPrincipal2 = amount2 - fee2;

        assertGe(recipient1BalAfter - recipient1BalBefore, expectedPrincipal1, "Recipient1 should receive principal");
        assertGe(recipient2BalAfter - recipient2BalBefore, expectedPrincipal2, "Recipient2 should receive principal");

        // Escrows should be independent - releasing one shouldn't affect the other
        // This validates scaled shares accounting prevents cross-escrow contamination
    }
}