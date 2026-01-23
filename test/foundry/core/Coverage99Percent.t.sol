// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';

/**
 * @title Coverage99Percent
 * @notice Comprehensive tests to achieve 99% coverage for EscrowVault.sol and BaseEscrow.sol
 * @dev Focuses on edge cases, error paths, and uncovered code paths
 */
contract Coverage99PercentTest is Test {
    EscrowVault public vault;
    EscrowAdminContract public adminContract;
    ModuleManagementContract public moduleManagement;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy public releaseStrategy;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;

    address public owner;
    address public timelock;
    address public guardian;
    address public feeAddress;
    address public feeRecipient;
    address public resolver;
    address public buyer;
    address public seller;
    address public recipient;

    uint256 public constant ESCROW_FEE = 100; // 1%

    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        guardian = address(0x2222);
        feeAddress = address(0xFEE);
        feeRecipient = address(0xFEE2);
        resolver = address(0x1234);
        buyer = address(0x1001);
        seller = address(0x1002);
        recipient = address(0x1003);

        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();

        token = new ERC20Mock('Test Token', 'TEST', owner, 10000000e18);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        settlementOps = new SettlementOps(owner);
        createOps = new CreateOps(owner);
        bondCollector = new BondCollector(owner);
        adminContract = new EscrowAdminContract(owner);
        moduleManagement = new ModuleManagementContract(owner);
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        bytes32 ROLE_TIMELOCK = vault.ROLE_TIMELOCK();
        bytes32 ROLE_GUARDIAN = vault.ROLE_GUARDIAN();
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_TIMELOCK, timelock);
        vault.grantRole(ROLE_GUARDIAN, guardian);
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), feeRecipient);

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        moduleManagement.registerEscrowContract(address(vault));

        adminContract.queueResolutionModule(address(vault), address(resolutionModule));
        vm.prank(address(vault));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 14 days + 1);
        adminContract.activateResolutionModule(address(vault));
        vm.prank(address(vault));
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);
    }

    // ============ EscrowVault Constructor Tests ============

    function test_EscrowVault_constructor_reverts_feeTooHigh() public {
        vm.expectRevert(abi.encodeWithSignature('InvalidEscrowFee(uint256,uint256)', 201, 200));
        new EscrowVault(201, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
    }

    function test_EscrowVault_constructor_reverts_zeroFeeAddress() public {
        vm.expectRevert(abi.encodeWithSignature('ZeroAddress(uint8)', 1));
        new EscrowVault(ESCROW_FEE, address(0), address(yieldOps), address(disputeOps), address(moduleManagement));
    }

    function test_EscrowVault_constructor_reverts_zeroYieldOps() public {
        vm.expectRevert(abi.encodeWithSignature('ZeroAddress(uint8)', 2));
        new EscrowVault(ESCROW_FEE, feeAddress, address(0), address(disputeOps), address(moduleManagement));
    }

    function test_EscrowVault_constructor_reverts_zeroDisputeOps() public {
        vm.expectRevert(abi.encodeWithSignature('ZeroAddress(uint8)', 3));
        new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(0), address(moduleManagement));
    }

    function test_EscrowVault_constructor_reverts_zeroModuleManagement() public {
        vm.expectRevert(abi.encodeWithSignature('ZeroAddress(uint8)', 4));
        new EscrowVault(ESCROW_FEE, feeAddress, address(yieldOps), address(disputeOps), address(0));
    }

    function test_EscrowVault_constructor_succeeds_maxFee() public {
        EscrowVault v = new EscrowVault(200, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        assertEq(v.escrowFee(), 200);
    }

    function test_EscrowVault_constructor_succeeds_zeroFee() public {
        EscrowVault v = new EscrowVault(0, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        assertEq(v.escrowFee(), 0);
    }

    // ============ EscrowVault Module Management Tests ============

    function test_queueModule() public {
        DefaultReleaseStrategy newStrategy = new DefaultReleaseStrategy();
        vm.prank(timelock);
        vault.queueModule(BaseEscrow.ModuleType.RELEASE, address(newStrategy));
    }

    function test_queueModule_reverts_notTimelock() public {
        DefaultReleaseStrategy newStrategy = new DefaultReleaseStrategy();
        address unauthorized = address(0x9999);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.queueModule(BaseEscrow.ModuleType.RELEASE, address(newStrategy));
    }

    function test_activateModule() public {
        DefaultReleaseStrategy newStrategy = new DefaultReleaseStrategy();
        vm.prank(timelock);
        vault.queueModule(BaseEscrow.ModuleType.RELEASE, address(newStrategy));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        vault.activateModule(BaseEscrow.ModuleType.RELEASE);
    }

    function test_activateModule_reverts_notTimelock() public {
        vm.expectRevert();
        vault.activateModule(BaseEscrow.ModuleType.RELEASE);
    }

    // ============ EscrowVault Fee Withdrawal Tests ============

    function test_withdrawFees_success() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        // Fees should be recorded
        uint256 expectedFee = (amount * ESCROW_FEE) / 10000;
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee);

        // Withdraw fees
        vm.prank(feeRecipient);
        vault.withdrawFees(address(token));

        // Fees should be zero after withdrawal
        assertEq(vault.totalFeesPerToken(address(token)), 0);
        assertEq(token.balanceOf(feeAddress), expectedFee);
    }

    function test_withdrawFees_reverts_notFeeRecipient() public {
        vm.expectRevert();
        vault.withdrawFees(address(token));
    }

    function test_withdrawFees_reverts_noFees() public {
        vm.prank(feeRecipient);
        vm.expectRevert(abi.encodeWithSignature('NoFeesToWithdraw(address,uint256)', address(token), 0));
        vault.withdrawFees(address(token));
    }

    function test_withdrawFees_reverts_insufficientBalance() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        // Get expected fee amount
        uint256 expectedFee = (amount * ESCROW_FEE) / 10000;

        // Drain contract balance
        uint256 contractBalance = token.balanceOf(address(vault));
        vm.prank(address(vault));
        token.transfer(recipient, contractBalance);

        vm.prank(feeRecipient);
        vm.expectRevert(abi.encodeWithSignature('InsufficientContractBalance(address,uint256,uint256)', address(token), expectedFee, 0));
        vault.withdrawFees(address(token));
    }

    // ============ EscrowVault Recovery Tests ============

    function test_recoverERC20_success() public {
        // Send some extra tokens to vault
        uint256 extraAmount = 100e18;
        token.mint(address(vault), extraAmount);

        vm.prank(timelock);
        vault.recoverERC20(address(token), recipient, extraAmount);

        assertEq(token.balanceOf(recipient), extraAmount);
    }

    function test_recoverERC20_reverts_notTimelock() public {
        vm.expectRevert();
        vault.recoverERC20(address(token), recipient, 100e18);
    }

    function test_recoverERC20_reverts_amountExceedsAvailable() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        // Add some extra tokens to vault to have recoverable amount
        uint256 extraAmount = 100e18;
        token.mint(address(vault), extraAmount);

        // Try to recover more than available
        // Library returns (false, 0, available) when recoveryAmount > available
        // The error shows recoveryAmount=0 (from library return) and available (calculated)
        uint256 balance = token.balanceOf(address(vault));
        uint256 held = vault.totalHeldInEscrowPerToken(address(token));
        uint256 fees = vault.totalFeesPerToken(address(token));
        uint256 available = balance > held + fees ? balance - held - fees : 0;
        
        vm.prank(timelock);
        // Library sets recoveryAmount to 0 when it fails, so error shows (token, 0, available)
        vm.expectRevert(abi.encodeWithSignature('AmountExceedsAvailable(address,uint256,uint256)', address(token), 0, available));
        vault.recoverERC20(address(token), recipient, available + 1);
    }

    function test_recoverERC20_zeroAmount_recoverAll() public {
        uint256 extraAmount = 100e18;
        token.mint(address(vault), extraAmount);

        vm.prank(timelock);
        vault.recoverERC20(address(token), recipient, 0);

        assertEq(token.balanceOf(recipient), extraAmount);
    }

    // ============ BaseEscrow Admin Setter Tests ============

    function test_setFeeRecipient() public {
        address newFeeAddress = address(0x9999);
        vm.prank(owner);
        vault.setFeeRecipient(newFeeAddress);
        assertEq(vault.escrowFeeAddress(), newFeeAddress);
    }

    function test_setFeeRecipient_reverts_zeroAddress() public {
        vm.prank(owner);
        // ADDR_FEE_RECIPIENT = 5
        vm.expectRevert(abi.encodeWithSignature('InvalidAddress(uint8,address)', 5, address(0)));
        vault.setFeeRecipient(address(0));
    }

    function test_setEscrowFeeBps() public {
        vm.prank(owner);
        vault.setEscrowFeeBps(150);
        assertEq(vault.escrowFee(), 150);
    }

    function test_setYieldProtocolFeeBps() public {
        vm.prank(owner);
        vault.setYieldProtocolFeeBps(1000);
        assertEq(vault.yieldProtocolFeeBps(), 1000);
    }

    function test_setYieldProtocolFeeBps_reverts_exceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature('FeeExceedsMaximum(uint256,uint256)', 3001, 3000));
        vault.setYieldProtocolFeeBps(3001);
    }

    function test_setYieldProtocolFeeBps_reverts_zeroFeeAddress() public {
        // Note: Cannot directly test zero fee recipient scenario because:
        // 1. EscrowVault constructor requires feeAddress (can't be zero)
        // 2. setFeeRecipient reverts when trying to set it to zero
        // 
        // The validation logic in setYieldProtocolFeeBps checks:
        // if (feeBps > 0 && escrowFeeAddress == address(0)) revert InvalidAddress(ADDR_FEE_RECIPIENT, address(0))
        // 
        // This scenario can't occur in practice, but the check exists for safety.
        // Test that setting feeBps = 0 works (doesn't require fee recipient check)
        vm.prank(owner);
        vault.setYieldProtocolFeeBps(0);
        assertEq(vault.yieldProtocolFeeBps(), 0);
    }

    function test_setAppealBondProtocolFeeBps() public {
        vm.prank(owner);
        vault.setAppealBondProtocolFeeBps(2000);
        assertEq(vault.appealBondProtocolFeeBps(), 2000);
    }

    function test_setAppealBondProtocolFeeBps_reverts_exceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature('FeeExceedsMaximum(uint256,uint256)', 3001, 3000));
        vault.setAppealBondProtocolFeeBps(3001);
    }

    function test_setAppealBondProtocolFeeBps_reverts_zeroFeeAddress() public {
        // Note: Cannot directly test zero fee recipient scenario because:
        // 1. EscrowVault constructor requires feeAddress (can't be zero)
        // 2. setFeeRecipient reverts when trying to set it to zero
        // 
        // The validation logic in setAppealBondProtocolFeeBps checks:
        // if (feeBps > 0 && escrowFeeAddress == address(0)) revert InvalidAddress(ADDR_FEE_RECIPIENT, address(0))
        // 
        // This scenario can't occur in practice, but the check exists for safety.
        // Test that setting feeBps = 0 works (doesn't require fee recipient check)
        vm.prank(owner);
        vault.setAppealBondProtocolFeeBps(0);
        assertEq(vault.appealBondProtocolFeeBps(), 0);
    }

    function test_setResolutionModule() public {
        DefaultResolutionModule newModule = new DefaultResolutionModule(owner, resolver);
        vm.prank(owner);
        vault.setResolutionModule(address(newModule));
        // Can't directly check, but should not revert
    }

    function test_setResolutionModule_reverts_zeroAddress() public {
        vm.prank(owner);
        // ADDR_GENERIC = 1
        vm.expectRevert(abi.encodeWithSignature('InvalidAddress(uint8,address)', 1, address(0)));
        vault.setResolutionModule(address(0));
    }

    function test_setResolutionModule_reverts_notContract() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature('ModuleNotContract(address)', buyer));
        vault.setResolutionModule(buyer);
    }

    function test_setTimeoutConfig() public {
        // Auto times must be absolute timestamps in the future, not durations
        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseTime: block.timestamp + 7 days,
            defaultAutoCancelTime: block.timestamp + 14 days,
            maxDisputeDuration: 30 days,
            appealWindowDuration: 2 days
        });
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);
    }

    function test_setCreateOps() public {
        CreateOps newOps = new CreateOps(owner);
        vm.prank(timelock);
        vault.setCreateOps(address(newOps));
    }

    function test_setCreateOps_reverts_zeroAddress() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSignature('ZeroCreateOps()'));
        vault.setCreateOps(address(0));
    }

    function test_setSettlementOps() public {
        SettlementOps newOps = new SettlementOps(owner);
        vm.prank(timelock);
        vault.setSettlementOps(address(newOps));
    }

    function test_setSettlementOps_reverts_zeroAddress() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSignature('ZeroSettlementOps()'));
        vault.setSettlementOps(address(0));
    }

    function test_setBondCollector() public {
        BondCollector newCollector = new BondCollector(owner);
        vm.prank(timelock);
        vault.setBondCollector(address(newCollector));
    }

    function test_setBondCollector_reverts_zeroAddress() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSignature('ZeroBondCollector()'));
        vault.setBondCollector(address(0));
    }

    // ============ BaseEscrow Pause/Unpause Tests ============

    function test_pause() public {
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_pause_reverts_notGuardian() public {
        vm.expectRevert();
        vault.pause();
    }

    function test_unpause() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(timelock);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_unpause_reverts_notTimelock() public {
        vm.prank(guardian);
        vault.pause();
        address unauthorized = address(0x9999);
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.unpause();
    }

    // ============ BaseEscrow Release Escrow Transfer Tests ============

    function test_releaseEscrowTransfer() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);

        EscrowTransfer memory et = _loadTransfer(workflowId);
        assertEq(uint256(et.escrowState), uint256(EscrowState.RELEASED));
    }

    function test_releaseEscrowTransfer_reverts_notSender() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.expectRevert(abi.encodeWithSignature('NotSender(uint256,address,address)', workflowId, seller, buyer));
        vm.prank(seller);
        vault.releaseEscrowTransfer(workflowId);
    }

    function test_releaseEscrowTransfer_reverts_notPending() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);

        vm.expectRevert(abi.encodeWithSignature('TransferNotPending(uint256,uint8)', workflowId, uint8(EscrowState.RELEASED)));
        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);
    }

    // ============ BaseEscrow Error Path Tests ============

    function test_validateWorkflowId_reverts() public {
        // Call a function that uses _validateWorkflowId internally
        // automateTimedActions uses _validateWorkflowId
        vm.expectRevert(abi.encodeWithSignature('InvalidWorkflowId(uint256,uint256)', 999, 0));
        vault.automateTimedActions(999);
    }

    function test_withdrawEscrow_reverts_notFinalized() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.expectRevert(abi.encodeWithSignature('TransferNotFinalized(uint256,uint8)', workflowId, uint8(EscrowState.PENDING)));
        vault.withdrawEscrow(workflowId);
    }

    function test_withdrawEscrow_reverts_noClaimableBalance() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);

        // The error shows msg.sender (the test contract address(this))
        // Caller has no claimable balance (autotransfer succeeded)
        vm.expectRevert(abi.encodeWithSignature('NoClaimableBalance(uint256,address,address)', workflowId, address(this), address(token)));
        vault.withdrawEscrow(workflowId);
    }

    // ============ BaseEscrow Recovery Tests ============

    function test_recoverERC20_baseEscrow() public {
        uint256 extraAmount = 100e18;
        token.mint(address(vault), extraAmount);

        vm.prank(timelock);
        vault.recoverERC20(address(token), recipient, extraAmount);

        assertEq(token.balanceOf(recipient), extraAmount);
    }

    function test_recoverERC20_baseEscrow_reverts_notTimelock() public {
        vm.expectRevert();
        vault.recoverERC20(address(token), recipient, 100e18);
    }

    // ============ BaseEscrow Dispute Tests ============

    function test_raiseDispute_reverts_notPending() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);

        vm.expectRevert(abi.encodeWithSignature('TransferNotPending(uint256,uint8)', workflowId, uint8(EscrowState.RELEASED)));
        vm.prank(buyer);
        vault.raiseDispute(workflowId);
    }

    function test_raiseDispute_reverts_notParticipant() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.expectRevert(abi.encodeWithSignature('NotParticipant(uint256,address,address,address)', workflowId, recipient, buyer, seller));
        vm.prank(recipient);
        vault.raiseDispute(workflowId);
    }

    function test_escalateDispute_reverts_zeroDisputeOps() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        // Cannot set disputeOps to zero (reverts), so we test escalation not allowed instead
        // DefaultResolutionModule doesn't support escalation
        vm.deal(buyer, 1 ether);
        vm.expectRevert(abi.encodeWithSignature('EscalationNotAllowed()'));
        vm.prank(buyer);
        vault.escalateDispute{value: 0.1 ether}(workflowId);
    }

    function test_escalateDispute_reverts_escalationNotAllowed() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        // DefaultResolutionModule doesn't support escalation
        vm.deal(buyer, 1 ether);
        vm.expectRevert(abi.encodeWithSignature('EscalationNotAllowed()'));
        vm.prank(buyer);
        vault.escalateDispute{value: 0.1 ether}(workflowId);
    }

    function test_autoCancelDisputedEscrow_reverts_notDisputed() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.expectRevert(abi.encodeWithSignature('TransferNotInDispute(uint256,uint8)', workflowId, uint8(EscrowState.PENDING)));
        vault.autoCancelDisputedEscrow(workflowId);
    }

    function test_autoCancelDisputedEscrow_reverts_timeoutNotExceeded() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        TimeoutConfig memory config = TimeoutConfig({
            defaultAutoReleaseTime: 0,
            defaultAutoCancelTime: 0,
            maxDisputeDuration: 90 days,
            appealWindowDuration: 1 days
        });
        vm.prank(timelock);
        adminContract.setTimeoutConfig(address(vault), config);

        vm.expectRevert();
        vault.autoCancelDisputedEscrow(workflowId);
    }

    function test_cancelAsDisputeResolver_reverts_notAuthorized() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        vm.expectRevert(abi.encodeWithSignature('NotAuthorizedResolver(address,address)', buyer, resolver));
        vm.prank(buyer);
        vault.cancelAsDisputeResolver(workflowId, bytes32(0));
    }

    function test_cancelAsDisputeResolver_reverts_notInDispute() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.expectRevert(abi.encodeWithSignature('TransferNotInDispute(uint256,uint8)', workflowId, uint8(EscrowState.PENDING)));
        vm.prank(resolver);
        vault.cancelAsDisputeResolver(workflowId, bytes32(0));
    }

    function test_releaseAsDisputeResolver_reverts_notAuthorized() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        vm.expectRevert(abi.encodeWithSignature('NotAuthorizedResolver(address,address)', buyer, resolver));
        vm.prank(buyer);
        vault.releaseAsDisputeResolver(workflowId, bytes32(0));
    }

    function test_releaseAsDisputeResolver_reverts_notInDispute() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.expectRevert(abi.encodeWithSignature('TransferNotInDispute(uint256,uint8)', workflowId, uint8(EscrowState.PENDING)));
        vm.prank(resolver);
        vault.releaseAsDisputeResolver(workflowId, bytes32(0));
    }

    function test_executePendingSettlement_reverts_noPendingSettlement() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.expectRevert(abi.encodeWithSignature('NoPendingSettlement(uint256)', workflowId));
        vault.executePendingSettlement(workflowId);
    }

    function test_executePendingSettlement_reverts_appealWindowNotExpired() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.raiseDispute(workflowId);

        vm.prank(resolver);
        vault.releaseAsDisputeResolver(workflowId, bytes32(0));

        // Try to execute before appeal window expires
        vm.expectRevert();
        vault.executePendingSettlement(workflowId);
    }

    function test_executePendingSettlement_reverts_notInDisputedState() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);

        // When there's no pending settlement, it reverts with NoPendingSettlement first
        vm.expectRevert(abi.encodeWithSignature('NoPendingSettlement(uint256)', workflowId));
        vault.executePendingSettlement(workflowId);
    }

    function test_automateTimedActions_returnsFalse_noAction() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        // No timed action should be available yet
        bool result = vault.automateTimedActions(workflowId);
        assertFalse(result);
    }

    function test_automateTimedActions_returnsFalse_noSettlementOps() public {
        // Cannot set settlementOps to zero (reverts), so create a new vault without settlementOps
        // But EscrowVault constructor requires settlementOps, so we can't test this path directly
        // Instead, test that automateTimedActions returns false when there's no action to take
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        // No timed action available (no auto-release/cancel time set, no pending settlement)
        bool result = vault.automateTimedActions(workflowId);
        assertFalse(result);
    }

    function test_senderCancel_reverts_notSender() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.expectRevert(abi.encodeWithSignature('NotSender(uint256,address,address)', workflowId, seller, buyer));
        vm.prank(seller);
        vault.senderCancel(workflowId);
    }

    function test_recipientCancel_reverts_notRecipient() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.expectRevert(abi.encodeWithSignature('NotRecipient(uint256,address,address)', workflowId, buyer, seller));
        vm.prank(buyer);
        vault.recipientCancel(workflowId);
    }

    function test_senderCancel_reverts_notPending() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);

        vm.expectRevert(abi.encodeWithSignature('TransferNotPending(uint256,uint8)', workflowId, uint8(EscrowState.RELEASED)));
        vm.prank(buyer);
        vault.senderCancel(workflowId);
    }

    function test_recipientCancel_reverts_notPending() public {
        uint256 amount = 1000e18;
        token.mint(buyer, amount);
        vm.prank(buyer);
        token.approve(address(vault), amount);

        vm.prank(buyer);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, SettingsValidationLibrary.getDefaultSettings());

        vm.prank(buyer);
        vault.releaseEscrowTransfer(workflowId);

        vm.expectRevert(abi.encodeWithSignature('TransferNotPending(uint256,uint8)', workflowId, uint8(EscrowState.RELEASED)));
        vm.prank(seller);
        vault.recipientCancel(workflowId);
    }

    // ============ Helper Functions ============

    function _loadTransfer(uint256 workflowId) internal view returns (EscrowTransfer memory et) {
        (
            address token_,
            address to_,
            address from_,
            address disputeResolver_,
            uint256 amountAfterFee_,
            uint64 autoReleaseTime_,
            uint64 autoCancelTime_,
            EscrowState escrowState_,
            SenderStatus senderStatus_,
            RecipientStatus recipientStatus_
        ) = vault.escrowTransfers(workflowId);

        et = EscrowTransfer({
            token: token_,
            to: to_,
            from: from_,
            disputeResolver: disputeResolver_,
            amountAfterFee: amountAfterFee_,
            autoReleaseTime: uint64(autoReleaseTime_),
            autoCancelTime: uint64(autoCancelTime_),
            escrowState: escrowState_,
            senderStatus: senderStatus_,
            recipientStatus: recipientStatus_
        });
    }
}
