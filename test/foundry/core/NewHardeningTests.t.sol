// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/core/BaseEscrow.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";

contract NewHardeningTests is Test {
    EscrowVault public vault;
    CreateOps public createOps;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;

    address public owner = address(0x1);
    address public timelock = address(0x2);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public feeAddress = address(0xFEE);

    function setUp() public {
        vm.startPrank(owner);
        createOps = new CreateOps(owner);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        
        vault = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        vault.setCreateOps(address(createOps));
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        
        resolutionModule = new DefaultResolutionModule(owner, address(0xDEAD));
        moduleManagement.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        
        token = new ERC20Mock("Test", "TEST", buyer, 10000e18);
        
        vm.stopPrank();
        
        vm.prank(buyer);
        token.approve(address(vault), type(uint256).max);
    }

    // 1. Fuzz: autoTime around now, now+max, now+max+1
    function testFuzz_AutoTimeBounds(uint256 offset) public {
        // Bound offset to a reasonable range to avoid overflow when adding to block.timestamp
        offset = bound(offset, 0, 10 * 365 days);
        
        uint256 autoReleaseTime = block.timestamp + offset;
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;

        if (offset == 0) {
            // Reverts with AUTO_TIME_IN_PAST because it must be > block.timestamp
            vm.expectRevert(abi.encodeWithSelector(InvalidAutoTime.selector, AUTO_TIME_IN_PAST, autoReleaseTime, block.timestamp));
            vm.prank(buyer);
            vault.createEscrow(address(token), seller, 1000e18, settings);
        } else if (offset <= SettingsValidationLibrary.MAX_ESCROW_DURATION) {
            // Success
            vm.prank(buyer);
            vault.createEscrow(address(token), seller, 1000e18, settings);
        } else {
            // Reverts with AutoTimeExceedsMaxLimit
            uint256 maxAllowed = block.timestamp + SettingsValidationLibrary.MAX_ESCROW_DURATION;
            vm.expectRevert(abi.encodeWithSelector(AutoTimeExceedsMaxLimit.selector, autoReleaseTime, maxAllowed));
            vm.prank(buyer);
            vault.createEscrow(address(token), seller, 1000e18, settings);
        }
    }

    // 2. EOA allowed vs contract resolver policy
    function test_ResolverPolicy_EOA() public {
        address eoaResolver = address(0xE0A);
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.customResolver = eoaResolver;

        // Default: resolverMustBeContract = true
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, ADDR_INITIAL_RESOLVER, eoaResolver));
        vm.prank(buyer);
        vault.createEscrow(address(token), seller, 1000e18, settings);

        // Change policy to allow EOAs
        vm.prank(owner);
        createOps.setResolverPolicy(false);

        // Now it should succeed
        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, 1000e18, settings);
        
        (,,, address resolver,,,,,,) = vault.escrowTransfers(wid);
        assertEq(resolver, eoaResolver);
    }

    // 3. Yield tiny deposit: fallback path
    // Note: Since I removed MIN_YIELD_DEPOSIT, it should always attempt yield.
    // To test "graceful fallback", we would need a module that reverts on tiny amounts.
    function test_TinyYieldDeposit_Success() public {
        uint256 tinyAmount = SettingsValidationLibrary.MIN_ESCROW_AMOUNT; // 1000 wei
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;

        // Should succeed even with tiny amount because we removed the threshold
        vm.prank(buyer);
        uint256 wid = vault.createEscrow(address(token), seller, tinyAmount, settings);
        
        (,,,,uint256 amountAfterFee,,,,,) = vault.escrowTransfers(wid);
        assertGt(amountAfterFee, 0);
    }
}
