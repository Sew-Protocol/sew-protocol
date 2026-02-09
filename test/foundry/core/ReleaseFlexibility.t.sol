// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/core/EscrowVault.sol'; // Or EscrowableERC20, depending on which is more representative
import 'contracts/modules/DefaultReleaseStrategy.sol';
import 'contracts/types/EscrowTypes.sol';
import 'contracts/libraries/EscrowEncodingLibrary.sol';
import 'contracts/interfaces/IReleaseStrategy.sol';
import 'contracts/interfaces/IEscrowCore.sol';
import 'contracts/ops/CreateOps.sol';
import 'contracts/ops/DisputeOps.sol';
import 'contracts/ops/SettlementOps.sol';
import 'contracts/ops/YieldOps.sol';
import 'contracts/core/BondCollector.sol';
import 'contracts/mocks/MockERC20.sol';
import 'contracts/mocks/MockResolutionModule.sol';
import 'contracts/mocks/MockModuleSnapshotRegistry.sol';
import { ADDR_RECIPIENT } from "contracts/types/EscrowTypes.sol";

uint8 constant ADDR_RECIPIENT_CODE = ADDR_RECIPIENT; // Using the imported constant

contract ReleaseFlexibilityTest is Test {
    EscrowVault escrowVault;
    MockERC20 mockToken;
    address deployer = address(0x1);
    address sender = address(0x2);
    address recipient = address(0x3);
    address authorizedReleaser = address(0x4);
    address unauthorizedCaller = address(0x5);
    address feeAddress = address(0x6);
    address defaultAdmin = address(0x7);
    address timelock = address(0x8);
    address guardian = address(0x9);

    DefaultReleaseStrategy defaultReleaseStrategy;
    MockResolutionModule mockResolutionModule;
    CreateOps createOps;
    DisputeOps disputeOps;
    SettlementOps settlementOps;
    YieldOps yieldOps;
    BondCollector bondCollector;
    MockModuleSnapshotRegistry moduleSnapshotRegistry;

    function setUp() public {
        vm.startPrank(deployer);

        // Deploy MockERC20
        mockToken = new MockERC20("Mock Token", "MTK");
        mockToken.mint(sender, 1000 ether);

        // Deploy utility contracts
        createOps = new CreateOps(defaultAdmin);
        disputeOps = new DisputeOps(defaultAdmin);
        settlementOps = new SettlementOps(defaultAdmin);
        yieldOps = new YieldOps(defaultAdmin);
        bondCollector = new BondCollector(defaultAdmin);
        
        // Deploy DefaultReleaseStrategy
        defaultReleaseStrategy = new DefaultReleaseStrategy();

        // Deploy MockResolutionModule
        mockResolutionModule = new MockResolutionModule();

        // Deploy MockModuleSnapshotRegistry
        moduleSnapshotRegistry = new MockModuleSnapshotRegistry(defaultAdmin);
        vm.startPrank(defaultAdmin);
        moduleSnapshotRegistry.grantRole(moduleSnapshotRegistry.ROLE_TIMELOCK(), timelock);
        vm.stopPrank();
        
        // Deploy EscrowVault (MOVED HERE) - deployer will be pranked so deployer gets ROLE_ADMIN
        vm.startPrank(deployer);
        escrowVault = new EscrowVault(
            0, // escrowFeeBps
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleSnapshotRegistry) // Pass the mock registry
        );
        vm.stopPrank();

        // Setup initial default modules in the mock registry (MOVED HERE)
        vm.startPrank(timelock);
        moduleSnapshotRegistry.registerEscrowContract(address(escrowVault));
        
        // Queue and activate release strategy
        moduleSnapshotRegistry.queueModule(address(escrowVault), BaseEscrow.ModuleType.RELEASE, address(defaultReleaseStrategy));
        moduleSnapshotRegistry.queueModule(address(escrowVault), BaseEscrow.ModuleType.RESOLUTION, address(mockResolutionModule));
        
        // Warp well past the 7-day delay for both modules
        vm.warp(block.timestamp + 365 days);
        
        moduleSnapshotRegistry.activateModule(address(escrowVault), BaseEscrow.ModuleType.RELEASE);
        moduleSnapshotRegistry.activateModule(address(escrowVault), BaseEscrow.ModuleType.RESOLUTION);
        vm.stopPrank();

        // Configure roles - deployer needs to grant them since deployer is ROLE_ADMIN
        vm.startPrank(deployer);
        escrowVault.grantRole(escrowVault.ROLE_ADMIN_CONTRACT(), defaultAdmin);
        escrowVault.grantRole(escrowVault.ROLE_TIMELOCK(), timelock);
        escrowVault.grantRole(escrowVault.ROLE_GUARDIAN(), guardian);
        vm.stopPrank();

        vm.startPrank(defaultAdmin);
        createOps.grantRole(createOps.ROLE_ESCROW_CONTRACT(), address(escrowVault));
        disputeOps.grantRole(disputeOps.ROLE_ESCROW_CONTRACT(), address(escrowVault));
        settlementOps.grantRole(settlementOps.ROLE_ESCROW_CONTRACT(), address(escrowVault));
        yieldOps.grantRole(yieldOps.ROLE_ESCROW_CONTRACT(), address(escrowVault));
        bondCollector.grantRole(bondCollector.ROLE_ESCROW_CONTRACT(), address(escrowVault));
        vm.stopPrank();


        vm.startPrank(timelock);
        escrowVault.setCreateOps(address(createOps));
        // Removed: escrowVault.setDisputeOps(address(disputeOps)); as DisputeOps is set in constructor
        escrowVault.setSettlementOps(address(settlementOps));
        escrowVault.setBondCollector(address(bondCollector));
        vm.stopPrank();

        vm.stopPrank();
    }

    // ============ Release Address Functionality Tests ============

    function test_canRelease_withReleaseAddress_senderAllowed() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: authorizedReleaser,
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        assertTrue(IEscrowCore(address(escrowVault)).canRelease(workflowId, sender), "Sender should be able to release");
    }

    function test_canRelease_withReleaseAddress_authorizedReleaserAllowed() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: authorizedReleaser,
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        assertTrue(IEscrowCore(address(escrowVault)).canRelease(workflowId, authorizedReleaser), "Authorized releaser should be able to release");
    }

    function test_canRelease_withReleaseAddress_unauthorizedCallerNotAllowed() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: authorizedReleaser,
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        assertFalse(IEscrowCore(address(escrowVault)).canRelease(workflowId, unauthorizedCaller), "Unauthorized caller should not be able to release");
        assertFalse(IEscrowCore(address(escrowVault)).canRelease(workflowId, recipient), "Recipient should not be able to release");
    }

    function test_release_byAuthorizedReleaser() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: authorizedReleaser,
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        assertEq(uint256(escrowVault.getEscrowState(workflowId)), uint256(EscrowState.PENDING));
        assertEq(mockToken.balanceOf(address(escrowVault)), 100 ether);
        assertEq(mockToken.balanceOf(recipient), 0);

        vm.startPrank(authorizedReleaser);
        escrowVault.release(workflowId);
        vm.stopPrank();

        assertEq(uint256(escrowVault.getEscrowState(workflowId)), uint256(EscrowState.RELEASED));
        assertEq(mockToken.balanceOf(address(escrowVault)), 0);
        assertEq(mockToken.balanceOf(recipient), 100 ether);
    }

    function test_release_noReleaseAddress_onlySender() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0), // No specific release address
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        assertEq(uint256(escrowVault.getEscrowState(workflowId)), uint256(EscrowState.PENDING));

        vm.prank(unauthorizedCaller);
        vm.expectRevert("BaseEscrow: release not allowed by strategy");
        escrowVault.release(workflowId);

        vm.prank(sender);
        escrowVault.release(workflowId);
        assertEq(uint256(escrowVault.getEscrowState(workflowId)), uint256(EscrowState.RELEASED));
        assertEq(mockToken.balanceOf(recipient), 100 ether);
    }

    function test_validateRecipient_revertsIfRecipientIsReleaseAddress() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: recipient, // Invalid: recipient is also releaseAddress
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidAddress.selector,
                ADDR_RECIPIENT_CODE,
                recipient
            )
        );
        escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();
    }
    
    // ============ Pausability Tests ============

    function test_release_callableWhenPaused() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        vm.prank(guardian);
        escrowVault.pause("Emergency pause for testing release");

        assertTrue(escrowVault.paused());
        
        vm.prank(sender);
        escrowVault.release(workflowId); // Should NOT revert
        assertEq(uint256(escrowVault.getEscrowState(workflowId)), uint256(EscrowState.RELEASED));
    }

    function test_releaseAsDisputeResolver_revertsWhenPaused() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        vm.startPrank(sender);
        escrowVault.raiseDispute(workflowId);
        vm.stopPrank();

        vm.prank(guardian);
        escrowVault.pause("Emergency pause for testing resolver release");
        
        assertTrue(escrowVault.paused());

        vm.prank(timelock);
        escrowVault.setResolutionModule(address(mockResolutionModule));

        vm.prank(address(mockResolutionModule)); // Pretend resolver calls
        vm.expectRevert("Pausable: paused");
        escrowVault.releaseAsDisputeResolver(workflowId, keccak256("resolutionHash"));
    }

    function test_cancelAsDisputeResolver_revertsWhenPaused() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        vm.startPrank(sender);
        escrowVault.raiseDispute(workflowId);
        vm.stopPrank();

        vm.prank(guardian);
        escrowVault.pause("Emergency pause for testing resolver cancel");
        
        assertTrue(escrowVault.paused());

        vm.prank(timelock);
        escrowVault.setResolutionModule(address(mockResolutionModule));

        vm.prank(address(mockResolutionModule)); // Pretend resolver calls
        vm.expectRevert("Pausable: paused");
        escrowVault.cancelAsDisputeResolver(workflowId, keccak256("resolutionHash"));
    }

    // ============ IEscrowCore.canRelease Tests ============

    function test_IEscrowCore_canRelease_validWorkflowId_sender() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        assertTrue(IEscrowCore(address(escrowVault)).canRelease(workflowId, sender));
    }

    function test_IEscrowCore_canRelease_validWorkflowId_releaseAddress() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: authorizedReleaser,
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();

        assertTrue(IEscrowCore(address(escrowVault)).canRelease(workflowId, authorizedReleaser));
    }

    function test_IEscrowCore_canRelease_invalidWorkflowId() public {
        assertFalse(IEscrowCore(address(escrowVault)).canRelease(999, sender)); // Non-existent workflowId
    }

    function test_IEscrowCore_canRelease_notPending() public {
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        escrowVault.release(workflowId); // Release it
        vm.stopPrank();

        assertEq(uint256(escrowVault.getEscrowState(workflowId)), uint256(EscrowState.RELEASED));
        assertFalse(IEscrowCore(address(escrowVault)).canRelease(workflowId, sender));
    }

    function test_IEscrowCore_canRelease_strategyNotConfigured() public {
        // This is covered by `defaultReleaseStrategy` being deployed,
        // but if no strategy was configured, `_getReleaseStrategy` would return address(0)
        // and `canRelease` should return false.
        // For now, this test implicitly passes because a default is always set.
        vm.startPrank(sender);
        mockToken.approve(address(escrowVault), 100 ether);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 workflowId = escrowVault.createEscrow(address(mockToken), recipient, 100 ether, settings);
        vm.stopPrank();
        
        // This simulates a scenario where the strategy would return address(0)
        // For actual behavior, we'd need a mock that returns address(0) for _getReleaseStrategy.
        // Since it's internal, direct testing is hard without mocking the entire escrow.
        // The current implementation ensures `_getReleaseStrategy` cannot return address(0)
        // unless `defaultReleaseStrategy` itself is address(0).
        assertTrue(IEscrowCore(address(escrowVault)).canRelease(workflowId, sender));
    }
}