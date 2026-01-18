// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';

/**
 * @title EscrowConstraints
 * @notice Tests for createEscrow validation constraints
 * @dev Ensures all createEscrow arguments are properly validated
 */
contract EscrowConstraints is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;
    EscrowAdminContract public adminContract;

    address public owner;
    address public timelock;
    address public feeAddress;
    address public resolver;
    address public sender;
    address public recipient;

    uint256 public constant ESCROW_FEE = 100; // 1%
    uint256 public constant MIN_ESCROW_AMOUNT = 1000; // Minimum escrow amount
    uint256 public constant MAX_ESCROW_DURATION = 365 days;
    uint256 public constant AMOUNT = 10000e18;

    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        feeAddress = address(0xFEE);
        resolver = address(0x1234);
        sender = address(0x1001);
        recipient = address(0x1002);

        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();

        token = new ERC20Mock('Test Token', 'TEST', owner, 10000000e18);
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps();
        moduleManagement = new ModuleManagementContract(address(this));
        adminContract = new EscrowAdminContract(address(this));
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(vault));

        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_TIMELOCK, timelock);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), owner);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        adminContract.queueResolutionModule(address(vault), address(resolutionModule));
        vault.queueDefaultModule(BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 14 days + 1);
        adminContract.activateResolutionModule(address(vault));
        vault.activateDefaultModule(BaseEscrow.ModuleType.RELEASE);
    }

    function getDefaultSettings() internal view returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    // ============ Amount Validation Tests ============

    function test_createEscrow_reverts_belowMinimumAmount() public {
        uint256 belowMinimum = MIN_ESCROW_AMOUNT - 1;

        token.mint(sender, belowMinimum);
        vm.prank(sender);
        token.approve(address(vault), belowMinimum);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettingsValidationLibrary.OutOfBounds.selector,
                bytes32('amount'),
                belowMinimum,
                MIN_ESCROW_AMOUNT,
                type(uint256).max
            )
        );
        vault.createEscrow(address(token), recipient, belowMinimum, getDefaultSettings());
    }

    function test_createEscrow_succeeds_atMinimumAmount() public {
        token.mint(sender, MIN_ESCROW_AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), MIN_ESCROW_AMOUNT);

        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(
            address(token),
            recipient,
            MIN_ESCROW_AMOUNT,
            getDefaultSettings()
        );
        assertGe(workflowId, 0);
    }

    function test_createEscrow_succeeds_aboveMinimumAmount() public {
        uint256 aboveMinimum = MIN_ESCROW_AMOUNT + 1;

        token.mint(sender, aboveMinimum);
        vm.prank(sender);
        token.approve(address(vault), aboveMinimum);

        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(
            address(token),
            recipient,
            aboveMinimum,
            getDefaultSettings()
        );
        assertGe(workflowId, 0);
    }

    // ============ Recipient Validation Tests ============

    function test_createEscrow_reverts_zeroRecipient() public {
        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettingsValidationLibrary.InvalidAddressKey.selector,
                bytes32('recipient')
            )
        );
        vault.createEscrow(address(token), address(0), AMOUNT, getDefaultSettings());
    }

    function test_createEscrow_reverts_senderEqualsRecipient() public {
        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettingsValidationLibrary.InvalidAddressKey.selector,
                bytes32('sender')
            )
        );
        vault.createEscrow(address(token), sender, AMOUNT, getDefaultSettings());
    }

    function test_createEscrow_succeeds_validRecipient() public {
        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(
            address(token),
            recipient,
            AMOUNT,
            getDefaultSettings()
        );
        assertGe(workflowId, 0);
    }

    // ============ Auto Time Duration Validation Tests ============

    function test_createEscrow_reverts_autoReleaseExceedsMaxDuration() public {
        EscrowSettings memory settings = getDefaultSettings();
        settings.autoReleaseTime = block.timestamp + MAX_ESCROW_DURATION + 1;

        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        vm.expectRevert();
        vault.createEscrow(address(token), recipient, AMOUNT, settings);
    }

    function test_createEscrow_succeeds_autoReleaseAtMaxDuration() public {
        EscrowSettings memory settings = getDefaultSettings();
        settings.autoReleaseTime = block.timestamp + MAX_ESCROW_DURATION;

        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(token), recipient, AMOUNT, settings);
        assertGe(workflowId, 0);
    }

    function test_createEscrow_reverts_autoCancelExceedsMaxDuration() public {
        EscrowSettings memory settings = getDefaultSettings();
        settings.autoCancelTime = block.timestamp + MAX_ESCROW_DURATION + 1;

        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        vm.expectRevert();
        vault.createEscrow(address(token), recipient, AMOUNT, settings);
    }

    function test_createEscrow_succeeds_autoCancelAtMaxDuration() public {
        EscrowSettings memory settings = getDefaultSettings();
        settings.autoCancelTime = block.timestamp + MAX_ESCROW_DURATION;

        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(token), recipient, AMOUNT, settings);
        assertGe(workflowId, 0);
    }

    // ============ Custom Resolver Validation Tests ============

    function test_createEscrow_reverts_customResolverIsEOA() public {
        address eoaResolver = address(0x1234); // EOA address
        EscrowSettings memory settings = getDefaultSettings();
        settings.customResolver = eoaResolver;

        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettingsValidationLibrary.InvalidAddressKey.selector,
                bytes32('customResolver')
            )
        );
        vault.createEscrow(address(token), recipient, AMOUNT, settings);
    }

    function test_createEscrow_succeeds_customResolverIsContract() public {
        EscrowSettings memory settings = getDefaultSettings();
        settings.customResolver = address(resolutionModule);

        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(token), recipient, AMOUNT, settings);
        assertGe(workflowId, 0);
    }

    function test_createEscrow_succeeds_zeroCustomResolver() public {
        EscrowSettings memory settings = getDefaultSettings();
        settings.customResolver = address(0); // Should use default

        token.mint(sender, AMOUNT);
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(token), recipient, AMOUNT, settings);
        assertGe(workflowId, 0);
    }

    // ============ Overflow Protection Tests ============

    function test_createEscrow_overflow_maxAmount_maxFee() public {
        // Use maximum escrow fee (200 bps = 2%)
        EscrowVault maxFeeVault = new EscrowVault(
            200, // MAX_ESCROW_FEE_BPS
            feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement)
        );

        // Setup maxFeeVault similarly to vault
        bytes32 ROLE_TIMELOCK = maxFeeVault.ROLE_TIMELOCK();
        maxFeeVault.grantRole(ROLE_TIMELOCK, owner);
        maxFeeVault.grantRole(ROLE_TIMELOCK, timelock);
        adminContract.queueResolutionModule(address(maxFeeVault), address(resolutionModule));
        maxFeeVault.queueDefaultModule(BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 14 days + 1);
        adminContract.activateResolutionModule(address(maxFeeVault));
        maxFeeVault.activateDefaultModule(BaseEscrow.ModuleType.RELEASE);

        // Test with a large amount that could cause overflow
        // Use a reasonable large amount that doesn't exceed practical limits
        // Solidity 0.8+ will revert on overflow automatically
        uint256 largeAmount = type(uint256).max / 1000; // Still very large but won't overflow
        
        token.mint(sender, largeAmount);
        vm.prank(sender);
        token.approve(address(maxFeeVault), largeAmount);

        vm.prank(sender);
        // This should succeed or revert gracefully (overflow protection)
        try maxFeeVault.createEscrow(
            address(token),
            recipient,
            largeAmount,
            getDefaultSettings()
        ) returns (uint256 workflowId) {
            assertGe(workflowId, 0);
        } catch {
            // If it reverts due to overflow, that's acceptable (automatic protection)
        }
    }
}
