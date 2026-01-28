// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/libraries/ModuleGetterLibrary.sol";
import "../../../contracts/libraries/ModuleGetterConsolidationLibrary.sol";
import "../../../contracts/libraries/ModuleSnapshotLibrary.sol";
import "../../../contracts/libraries/BondHandlingLibrary.sol";
import "../../../contracts/libraries/DisputeRaiseLibrary.sol";
import "../../../contracts/libraries/DisputeEscalationLibrary.sol";
import "../../../contracts/libraries/TokenRecoveryLibrary.sol";
import "../../../contracts/core/BaseEscrow.sol";
import "../../../contracts/core/ModuleManagementContract.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/decentralized-resolution-module/IIncentiveModule.sol";

contract NewLibraryHarness {
    mapping(uint256 => BaseEscrow.ModuleSnapshot) public moduleSnapshots;
    mapping(address => uint256) public totalHeldInEscrowPerToken;
    mapping(address => uint256) public totalFeesPerToken;

    function setModuleSnapshot(uint256 workflowId, BaseEscrow.ModuleSnapshot memory snapshot) external {
        moduleSnapshots[workflowId] = snapshot;
    }

    function getModuleAddress(
        uint256 workflowId,
        BaseEscrow.ModuleType moduleType,
        ModuleManagementContract moduleManagement,
        address escrowContract
    ) external view returns (address) {
        return ModuleGetterLibrary.getModuleAddress(
            workflowId,
            moduleType,
            moduleSnapshots,
            moduleManagement,
            escrowContract
        );
    }

    function callIncentiveModuleHook(
        address incentiveModAddr,
        uint256 workflowId,
        address token,
        uint256 amountAfterFee,
        uint256 escrowFee,
        uint256 escrowFeeDenominator
    ) external returns (bool) {
        return DisputeRaiseLibrary.callIncentiveModuleHook(
            incentiveModAddr,
            workflowId,
            token,
            amountAfterFee,
            escrowFee,
            escrowFeeDenominator
        );
    }

    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external returns (bool success, uint256 recoveryAmount, uint256 available) {
        return TokenRecoveryLibrary.recoverERC20(
            totalHeldInEscrowPerToken,
            totalFeesPerToken,
            token,
            recipient,
            amount
        );
    }

    function setHeld(address token, uint256 amount) external {
        totalHeldInEscrowPerToken[token] = amount;
    }

    function setFees(address token, uint256 amount) external {
        totalFeesPerToken[token] = amount;
    }
    
    receive() external payable {}
}

contract MockIncentiveModule is IIncentiveModule {
    bool public failHook = false;
    bool public hookCalled = false;

    function setFailHook(bool _fail) external {
        failHook = _fail;
    }

    function onDisputeOpened(uint256, address, uint256, uint256, uint8) external override {
        hookCalled = true;
        if (failHook) revert("Mock failure");
    }

    function onResolverAssigned(uint256, address, uint8) external override {}
    function onDecisionSubmitted(uint256, address, uint8, DecentralizedResolverStructs.ResolutionOutcome, uint256) external override {}
    function onEscalated(uint256, uint8, uint8, address) external override {}
    function onDisputeFinalized(uint256, uint8, DecentralizedResolverStructs.ResolutionOutcome) external override {}
    function onResolverTimeout(uint256, address, uint8, uint8) external override {}
    function distributePayments(uint256, address, uint256) external override {}
    function getClaimablePayment(uint256, address) external view override returns (uint256) { return 0; }
    function supportsFeature(bytes4) external view override returns (bool) { return false; }
    function getRequiredAppealBond(uint256, uint8, uint8) external view override returns (uint256, address) { return (0, address(0)); }
    function recordAppealBond(uint256, address, address, uint256, address, uint8) external payable override {}
    function distributeAppealBond(uint256, uint8, bool) external override {}
}

contract MockResolutionModule {
    address public incentiveModule;
    constructor(address _incentiveModule) {
        incentiveModule = _incentiveModule;
    }
}

contract NewLibraryCoverageTest is Test {
    NewLibraryHarness public harness;
    ERC20Mock public token;
    ModuleManagementContract public moduleManagement;
    MockIncentiveModule public incentiveMod;

    function setUp() public {
        harness = new NewLibraryHarness();
        token = new ERC20Mock("Test", "TEST", address(harness), 1000);
        moduleManagement = new ModuleManagementContract(address(this));
        incentiveMod = new MockIncentiveModule();
    }

    // ============ ModuleGetterLibrary Tests ============

    function test_ModuleGetter_FromSnapshot() public {
        address resMod = address(0x123);
        BaseEscrow.ModuleSnapshot memory snapshot;
        snapshot.resolutionModule = resMod;
        harness.setModuleSnapshot(1, snapshot);

        address result = harness.getModuleAddress(1, BaseEscrow.ModuleType.RESOLUTION, moduleManagement, address(this));
        assertEq(result, resMod);
    }

    function test_ModuleGetter_FromDefault() public {
        address resMod = address(0x123);
        moduleManagement.registerEscrowContract(address(harness));
        moduleManagement.queueModule(address(harness), BaseEscrow.ModuleType.RESOLUTION, resMod);
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(harness), BaseEscrow.ModuleType.RESOLUTION);

        // Snapshot is empty
        address result = harness.getModuleAddress(1, BaseEscrow.ModuleType.RESOLUTION, moduleManagement, address(harness));
        assertEq(result, resMod);
    }

    // ============ ModuleGetterConsolidationLibrary Tests ============

    function test_ModuleGetterConsolidation() public {
        address addr = address(0x123);
        assertEq(address(ModuleGetterConsolidationLibrary.getReleaseStrategy(addr)), addr);
        assertEq(address(ModuleGetterConsolidationLibrary.getYieldGenerationModule(addr)), addr);
        assertEq(address(ModuleGetterConsolidationLibrary.getYieldDistributionModule(addr)), addr);
        assertEq(address(ModuleGetterConsolidationLibrary.getResolutionModule(addr, address(0x456))), addr);
        assertEq(address(ModuleGetterConsolidationLibrary.getResolutionModule(address(0), address(0x456))), address(0x456));
    }

    // ============ ModuleSnapshotLibrary Tests ============

    function test_ModuleSnapshot_getIncentiveModule() public {
        // Mock resolution module that has incentiveModule()
        MockResolutionModule resMod = new MockResolutionModule(address(incentiveMod));
        address result = ModuleSnapshotLibrary.getIncentiveModule(address(resMod));
        assertEq(result, address(incentiveMod));
    }

    function test_ModuleSnapshot_getIncentiveModule_Zero() public {
        address result = ModuleSnapshotLibrary.getIncentiveModule(address(0));
        assertEq(result, address(0));
    }

    // ============ DisputeRaiseLibrary Tests ============

    function test_DisputeRaise_HookSuccess() public {
        bool failure = harness.callIncentiveModuleHook(address(incentiveMod), 1, address(token), 1000, 100, 10000);
        assertFalse(failure);
        assertTrue(incentiveMod.hookCalled());
    }

    function test_DisputeRaise_HookFailure() public {
        incentiveMod.setFailHook(true);
        bool failure = harness.callIncentiveModuleHook(address(incentiveMod), 1, address(token), 1000, 100, 10000);
        assertTrue(failure);
    }

    function test_DisputeRaise_HookZeroAddress() public {
        bool failure = harness.callIncentiveModuleHook(address(0), 1, address(token), 1000, 100, 10000);
        assertFalse(failure);
    }

    // ============ TokenRecoveryLibrary Tests ============

    function test_TokenRecovery_Success() public {
        harness.setHeld(address(token), 500);
        harness.setFees(address(token), 100);
        // Total protected = 600. Balance = 1000. Available = 400.
        
        address recipient = address(0x999);
        (bool success, uint256 recoveryAmount, uint256 available) = harness.recoverERC20(address(token), recipient, 200);
        
        assertTrue(success);
        assertEq(recoveryAmount, 200);
        assertEq(available, 400);
        assertEq(token.balanceOf(recipient), 200);
    }

    function test_TokenRecovery_All() public {
        harness.setHeld(address(token), 500);
        harness.setFees(address(token), 100);
        
        address recipient = address(0x999);
        (bool success, uint256 recoveryAmount, uint256 available) = harness.recoverERC20(address(token), recipient, 0);
        
        assertTrue(success);
        assertEq(recoveryAmount, 400);
        assertEq(available, 400);
        assertEq(token.balanceOf(recipient), 400);
    }

    function test_TokenRecovery_FailExceeds() public {
        harness.setHeld(address(token), 500);
        harness.setFees(address(token), 100);
        
        address recipient = address(0x999);
        (bool success, uint256 recoveryAmount, uint256 available) = harness.recoverERC20(address(token), recipient, 401);
        
        assertFalse(success);
        assertEq(recoveryAmount, 0);
        assertEq(available, 400);
    }

    // ============ BondHandlingLibrary Tests ============

    function test_BondHandling_processBondWithFee() public {
        BondHandlingLibrary.BondProcessingResult memory res = BondHandlingLibrary.processBondWithFee(1000, address(0), 1000, address(0x123));
        assertTrue(res.success);
        assertEq(res.protocolFeeAmount, 100);
        assertEq(res.bondToRecord, 900);
    }

    function test_BondHandling_processBondNoFee() public {
        BondHandlingLibrary.BondProcessingResult memory res = BondHandlingLibrary.processBondWithFee(1000, address(0), 0, address(0x123));
        assertTrue(res.success);
        assertEq(res.protocolFeeAmount, 0);
        assertEq(res.bondToRecord, 1000);
    }

    // ============ DisputeEscalationLibrary Tests ============

    function test_DisputeEscalation_validateBondMsgValue() public {
        // ETH bond (token == 0)
        (bool valid, uint8 error) = DisputeEscalationLibrary.validateBondMsgValue(address(0), 100, 100);
        assertTrue(valid);
        assertEq(error, 0);

        (valid, error) = DisputeEscalationLibrary.validateBondMsgValue(address(0), 100, 99);
        assertFalse(valid);
        assertEq(error, 1);

        // ERC20 bond (token != 0)
        (valid, error) = DisputeEscalationLibrary.validateBondMsgValue(address(0x123), 100, 0);
        assertTrue(valid);
        assertEq(error, 0);

        (valid, error) = DisputeEscalationLibrary.validateBondMsgValue(address(0x123), 100, 1);
        assertFalse(valid);
        assertEq(error, 2);
    }

    function test_DisputeEscalation_processBondWithFeeCalculation() public {
        (BondHandlingLibrary.BondProcessingResult memory res, IIncentiveModule im) = 
            DisputeEscalationLibrary.processBondWithFeeCalculation(1000, address(0), address(incentiveMod), 1000, address(0x123));
        
        assertEq(address(im), address(incentiveMod));
        assertEq(res.protocolFeeAmount, 100);
        assertEq(res.bondToRecord, 900);
    }

    function test_DisputeEscalation_processBondWithFeeCalculation_Zero() public {
        (BondHandlingLibrary.BondProcessingResult memory res, IIncentiveModule im) = 
            DisputeEscalationLibrary.processBondWithFeeCalculation(0, address(0), address(incentiveMod), 1000, address(0x123));
        
        assertEq(address(im), address(0));
        assertEq(res.bondToRecord, 0);
    }
}
