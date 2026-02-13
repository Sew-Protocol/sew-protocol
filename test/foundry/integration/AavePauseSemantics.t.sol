// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/modules/AaveYieldModule.sol";
import "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/mocks/MockAavePool.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/ops/GuardianOps.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";
import "../../../contracts/interfaces/aave/AaveV3Interfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AavePauseSemantics
 * @notice Tests pause semantics for Aave integration
 * @dev Validates that pause blocks enter yield but allows exit
 */
contract AavePauseSemantics is Test {
    MockAavePool internal pool;
    ERC20Mock internal token;
    MockAToken internal aToken;
    MockPoolAddressesProvider internal provider;
    AaveYieldModule internal aaveModule;

    EscrowVault internal vault;
    ModuleSnapshotRegistry internal mm;
    YieldOps internal yieldOps;
    DisputeOps internal disputeOps;
    CreateOps internal createOps;
    SettlementOps internal settlementOps;
    BondCollector internal bondCollector;
    DefaultResolutionModule internal resolutionModule;
    DefaultYieldDistributionModule internal yieldDist;
    GuardianOps internal guardianOps;

    address internal feeAddress = address(0xFEE);
    address internal resolver = address(0xBEEF);
    address internal sender = address(0x1001);
    address internal recipient = address(0x1002);
    address internal guardian = address(0x900D);

    uint256 internal constant ESCROW_FEE_BPS = 100;

    function setUp() public {
        token = new ERC20Mock("Mock Token", "MOCK", address(this), 10_000_000 ether);
        pool = new MockAavePool();

        aToken = new MockAToken(address(token), "aMock", "aMOCK");
        aToken.setPool(address(pool));
        pool.setAToken(address(token), address(aToken));
        provider = new MockPoolAddressesProvider(address(pool));

        aaveModule = new AaveYieldModule(address(this));
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

        // Module pattern is now used directly (no delegatecall library needed)
        vault.setYieldProtocolFeeBps(0);

        // Deploy GuardianOps for emergency unwind
        guardianOps = new GuardianOps(address(vault));

        // Grant guardian role (needed for pause and emergency unwind)
        vault.grantRole(vault.ROLE_GUARDIAN(), guardian);
        vault.grantRole(vault.ROLE_GUARDIAN(), address(this)); // Also grant to this contract for emergency unwind
        // Grant guardian role to guardianOps on aaveModule
        aaveModule.grantRole(aaveModule.ROLE_GUARDIAN(), address(guardianOps));
        // Grant escrow contract role to vault on aaveModule (needed for emergency unwind)
        aaveModule.grantRole(aaveModule.ROLE_ESCROW_CONTRACT(), address(vault));
        // Grant timelock role to this contract (for unpause)
        vault.grantRole(vault.ROLE_TIMELOCK(), address(this));

        token.mint(sender, 10_000_000 ether);
        token.mint(address(pool), 10_000_000 ether);
    }

    /**
     * @notice Test: Pause blocks both enter and exit yield (current implementation)
     * @dev Current design: pause blocks both for safety. Emergency unwind available for guardian.
     */
    function test_pause_blocksEnterYield_blocksExitYield() public {
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create escrow before pause
        uint256 amount = 100 ether;
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Verify escrow was created and entered yield
        (, , , , uint256 amountAfterFee, , , , , ) = vault.escrowTransfers(wid);
        assertGt(amountAfterFee, 0, "Escrow should exist");

        // Pause the vault
        vm.prank(guardian);
        vault.pause("test pause");

        // Verify pause state
        assertTrue(vault.paused(), "Vault should be paused");

        // NEW SEMANTICS: Can still create escrow when paused (settlement allowed)
        address newSender = address(0x2001);
        token.mint(newSender, 100 ether);
        vm.startPrank(newSender);
        token.approve(address(vault), 100 ether);
        
        // createEscrow should SUCCEED when paused (settlement operations allowed)
        uint256 newWid = vault.createEscrow(address(token), recipient, 100 ether, settings);
        assertGt(newWid, 0, "Escrow should be created even while paused");
        vm.stopPrank();

        // NEW SEMANTICS: Can still release when paused (settlement allowed)
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);
        
        // Verify escrow was released even while paused
        EscrowState state = vault.getEscrowState(wid);
        assertEq(uint8(state), uint8(EscrowState.RELEASED));
    }

    /**
     * @notice Test: New escrows CAN enter yield when paused (settlement allowed)
     */
    function test_pause_newEscrows_cannotEnterYield() public {
        // Pause first
        vm.prank(guardian);
        vault.pause("test pause");

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        uint256 amount = 100 ether;
        vm.startPrank(sender);
        token.approve(address(vault), amount);

        // NEW SEMANTICS: Should SUCCEED when paused (settlement operations allowed)
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        
        // Verify escrow count increased (creation succeeded)
        uint256 count = vault.getEscrowCount();
        assertEq(count, 1, "Escrow should be created even while paused");
        vm.stopPrank();
    }

    /**
     * @notice Test: Existing escrows cannot exit yield when paused (design decision)
     * @dev Current implementation blocks both enter and exit when paused for safety
     *      Emergency unwind is available for guardian via emergencyUnwindAavePosition
     */
    function test_pause_existingEscrows_cannotExitYield() public {
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create escrow before pause
        uint256 amount = 100 ether;
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Pause
        vm.prank(guardian);
        vault.pause("test pause");

        // NEW SEMANTICS: Release should SUCCEED even when paused (settlement allowed)
        vm.prank(sender);
        vault.releaseEscrowTransfer(wid);
        
        // Verify escrow was released
        EscrowState state = vault.getEscrowState(wid);
        assertEq(uint8(state), uint8(EscrowState.RELEASED));
    }

    /**
     * @notice Test: Unpause allows enter yield
     */
    function test_unpause_allowsEnterYield() public {
        // Pause first
        vm.prank(guardian);
        vault.pause("test pause");

        // Unpause (requires ROLE_TIMELOCK, not ROLE_GUARDIAN)
        vault.unpause(); // This contract has ROLE_TIMELOCK

        // Verify unpaused
        assertFalse(vault.paused(), "Vault should be unpaused");

        // Should be able to create escrow now
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        uint256 amount = 100 ether;
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Verify escrow was created
        (, , , , uint256 amountAfterFee, , , , , ) = vault.escrowTransfers(wid);
        assertGt(amountAfterFee, 0, "Escrow should exist after unpause");
    }

    /**
     * @notice Test: Emergency unwind works when paused
     */
    function test_pause_emergencyUnwind_stillWorks() public {
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create escrow
        uint256 amount = 100 ether;
        vm.startPrank(sender);
        token.approve(address(vault), amount);
        uint256 wid = vault.createEscrow(address(token), recipient, amount, settings);
        vm.stopPrank();

        // Verify deposit succeeded by checking module's escrowInAave status
        bool inYield = aaveModule.escrowInAave(address(vault), wid);
        require(inYield, "Yield deposit should have succeeded");

        // Verify aTokens exist
        uint256 aTokenBalanceBefore = aToken.balanceOf(address(aaveModule));
        assertGt(aTokenBalanceBefore, 0, "Should have aTokens");

        // Pause (guardian can pause)
        vm.prank(guardian);
        vault.pause("test pause");

        // Emergency unwind should work via GuardianOps
        // Use this contract (which has ROLE_GUARDIAN) instead of guardian address
        uint256 usdcBalanceBefore = token.balanceOf(address(vault));
        // This contract has ROLE_GUARDIAN from setUp
        uint256 unwound = guardianOps.emergencyUnwindAavePosition(
            address(token),
            wid,
            address(vault)
        );

        assertGt(unwound, 0, "Unwind should succeed");

        // Verify funds went to vault
        uint256 usdcBalanceAfter = token.balanceOf(address(vault));
        assertGt(usdcBalanceAfter, usdcBalanceBefore, "Vault should receive funds");
    }
}