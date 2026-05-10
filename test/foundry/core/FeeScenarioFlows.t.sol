// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/modules/DefaultReleaseStrategy.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/core/modules/DefaultResolutionModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";

import "../../../contracts/ops/YieldOps.sol";
import "../../../contracts/ops/DisputeOps.sol";
import "../../../contracts/ops/SettlementOps.sol";
import "../../../contracts/ops/CreateOps.sol";
import "../../../contracts/core/BondCollector.sol";
import "../../../contracts/core/ModuleSnapshotRegistry.sol";
import "../../../contracts/admin/EscrowGovernanceTimelock.sol";

import "../../../contracts/shared/interfaces/IIncentiveModule.sol";

contract MockIncentiveModule is IIncentiveModule {
    event AppealBondRecorded(uint256 workflowId, address escrowContract, address depositor, address escalatedBy, uint256 amount, address token, uint8 newLevel);

    // ---- Core lifecycle hooks (no-op for tests) ----
    function onDisputeOpened(uint256, address, address, uint256, uint256, uint8) external override {}
    function onResolverAssigned(uint256, address, address, uint8) external override {}
    function onDecisionSubmitted(
        uint256,
        address,
        address,
        uint8,
        ResolutionOutcome,
        uint256
    ) external override {}
    function onEscalated(uint256, address, uint8, uint8, address) external override {}
    function onDisputeFinalized(uint256, address, uint8, ResolutionOutcome) external override {}
    function onResolverTimeout(uint256, address, address, uint8, uint8) external override {}

    // ---- Payment distribution (no-op for tests) ----
    function distributePayments(uint256, address, address, uint256) external override {}
    function getClaimablePayment(uint256, address, address) external pure override returns (uint256 amount) {
        return 0;
    }

    // ---- V2+ optional surface ----
    function supportsFeature(bytes4) external pure override returns (bool supported) {
        return false;
    }

    function getRequiredAppealBond(
        uint256,
        address,
        uint8,
        uint8
    ) external pure override returns (uint256 bondAmount, address token) {
        return (0, address(0));
    }

    function recordAppealBond(
        uint256 workflowId,
        address escrowContract,
        address depositor,
        address escalatedBy,
        uint256 amount,
        address token,
        uint8 newLevel
    ) external payable override {
        // Accept ETH if token == address(0) (BondCollector uses low-level call with value)
        emit AppealBondRecorded(workflowId, escrowContract, depositor, escalatedBy, amount, token, newLevel);
    }

    function distributeAppealBond(uint256, address, uint8, bool) external override {}
}

/**
 * @title FeeScenarioFlowsTest
 * @notice Scenario tests for escrow fee (1%) accounting + withdrawals.
 *
 * Scenarios:
 * - Purchase (create -> release) with 1% escrow fee
 * - Refund (create -> recipientCancel + senderCancel) with 1% escrow fee
 * - DAO fee withdrawal for ERC20 fees
 * - ProtocolFeeCollected event emitted for appeal-bond protocol fee (BondCollector)
 */
contract FeeScenarioFlowsTest is Test {
    EscrowVault public vault;
    DefaultReleaseStrategy public releaseStrategy;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;

    address public owner;
    address public timelock;
    address public dao; // fee withdrawal operator (caller)
    address public treasury; // fee recipient (escrowFeeAddress)
    address public resolver;
    address public buyer;
    address public seller;

    uint256 public constant INITIAL_ESCROW_FEE_BPS = 0; // start at 0 and then set to 1%
    uint256 public constant ESCROW_FEE_BPS = 100; // 1%

    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");

    function setUp() public {
        owner = address(this);
        timelock = owner;
        dao = address(0xDA0);
        treasury = address(0xFEE);
        resolver = address(0x1234);
        buyer = address(0x1001);
        seller = address(0x1002);

        // Core components
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        releaseStrategy = new DefaultReleaseStrategy();
        token = new ERC20Mock("Token", "TKN", owner, 10000000e18);
        yieldOps = new YieldOps(owner);
        disputeOps = new DisputeOps(owner);
        settlementOps = new SettlementOps(owner);
        createOps = new CreateOps(owner);
        bondCollector = new BondCollector(owner);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        adminContract = new EscrowGovernanceTimelock(owner);

        // Vault starts with 0% fee; we'll slow-lane set to 1% in tests.
        vault = new EscrowVault(INITIAL_ESCROW_FEE_BPS, treasury, address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(vault));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        // Register vault on ops contracts
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        // Wire vault roles + ops
        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);

        // Fee withdraw role for DAO
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), dao);

        // EscrowGovernanceTimelock slow-lane operator
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), timelock);

        // Ops wiring (timelock-gated on the vault)
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        // Activate a resolution module so create flows have a valid default resolver path.
        adminContract.queueResolutionModule(address(vault), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(vault));
    }

    function _setEscrowFeeToOnePercent() internal {
        // slow lane update
        adminContract.queueEscrowFee(address(vault), ESCROW_FEE_BPS);
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateEscrowFee(address(vault));
        assertEq(vault.escrowFee(), ESCROW_FEE_BPS, "escrow fee should be 1%");
    }

    function _defaultSettings() internal pure returns (EscrowSettings memory) {
        return SettingsValidationLibrary.getDefaultSettings();
    }

    function test_purchaseScenario_feeAccountingAndDaoWithdraw() public {
        _setEscrowFeeToOnePercent();

        uint256 amount = 1000e18;
        uint256 expectedFee = (amount * ESCROW_FEE_BPS) / 10000; // 10e18
        uint256 expectedAmountAfterFee = amount - expectedFee; // 990e18

        // fund buyer
        token.transfer(buyer, amount);

        // pre-state
        assertEq(vault.totalFeesPerToken(address(token)), 0, "fees should start at 0");
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0, "held should start at 0");

        // create (purchase)
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, _defaultSettings());
        vm.stopPrank();

        // after create
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee, "fee should be recorded");
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), expectedAmountAfterFee, "held should equal amountAfterFee");
        assertEq(token.balanceOf(address(vault)), amount, "vault should hold principal+fee pre-release");

        // release (purchase completes)
        vm.prank(buyer);
        vault.release(workflowId);

        // after release
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0, "held should be zero after release");
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee, "fees should remain until withdrawn");
        assertEq(token.balanceOf(seller), expectedAmountAfterFee, "seller receives amountAfterFee");
        assertEq(token.balanceOf(address(vault)), expectedFee, "vault retains only fees post-release");

        // DAO withdraws fees to treasury
        uint256 treasuryBal0 = token.balanceOf(treasury);

        vm.prank(dao);
        vm.expectEmit(true, true, false, true, address(vault));
        emit EscrowVault.FeesWithdrawn(address(token), expectedFee);
        vault.withdrawFees(address(token));

        // after withdraw
        assertEq(vault.totalFeesPerToken(address(token)), 0, "fees should be zero after withdrawal");
        assertEq(token.balanceOf(address(vault)), 0, "vault should have no remaining tokens after fee withdrawal");
        assertEq(token.balanceOf(treasury) - treasuryBal0, expectedFee, "treasury receives withdrawn fees");
    }

    function test_refundScenario_feeAccountingAndDaoWithdraw() public {
        _setEscrowFeeToOnePercent();

        uint256 amount = 1000e18;
        uint256 expectedFee = (amount * ESCROW_FEE_BPS) / 10000; // 10e18
        uint256 expectedAmountAfterFee = amount - expectedFee; // 990e18

        token.transfer(buyer, amount);

        // create
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        uint256 workflowId = vault.createEscrow(address(token), seller, amount, _defaultSettings());
        vm.stopPrank();

        // confirm create accounting
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee, "fee should be recorded");
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), expectedAmountAfterFee, "held should equal amountAfterFee");

        // cancel + refund (seller then buyer)
        vm.prank(seller);
        vault.recipientCancel(workflowId);

        uint256 buyerBal0 = token.balanceOf(buyer);
        vm.prank(buyer);
        vault.senderCancel(workflowId);
        uint256 buyerDelta = token.balanceOf(buyer) - buyerBal0;
        assertEq(buyerDelta, expectedAmountAfterFee, "buyer refunded amountAfterFee");

        // after refund
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0, "held should be zero after refund");
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee, "fees should remain until withdrawn");
        assertEq(token.balanceOf(address(vault)), expectedFee, "vault retains only fees post-refund");

        // DAO withdraws fees to treasury
        uint256 treasuryBal0 = token.balanceOf(treasury);
        vm.prank(dao);
        vault.withdrawFees(address(token));
        assertEq(vault.totalFeesPerToken(address(token)), 0, "fees should be zero after withdrawal");
        assertEq(token.balanceOf(treasury) - treasuryBal0, expectedFee, "treasury receives withdrawn fees");
    }

    function test_protocolFeeCollectedEvent_emittedForAppealBond() public {
        // This validates ProtocolFeeCollected emission (appeal-bond protocol fee) at the BondCollector layer.
        MockIncentiveModule incentive = new MockIncentiveModule();

        // Allow this test contract to call BondCollector.collectBond (ROLE_ESCROW_CONTRACT)
        bondCollector.registerEscrowContract(address(this));

        uint256 workflowId = 77;
        uint256 bondAmount = 10 ether;
        uint256 feeBps = 1000; // 10%
        uint256 expectedFee = (bondAmount * feeBps) / 10000; // 1 ether
        uint256 expectedToRecord = bondAmount - expectedFee; // 9 ether

        vm.deal(address(this), bondAmount);
        vm.deal(treasury, 0);

        // Expect the protocol fee event
        vm.expectEmit(true, true, true, true, address(bondCollector));
        emit BondCollector.ProtocolFeeCollected(1, workflowId, address(0), bondAmount, feeBps, expectedFee);

        uint256 treasuryEth0 = treasury.balance;
        bool ok = bondCollector.collectBond{value: bondAmount}(
            workflowId,
            IIncentiveModule(address(incentive)),
            bondAmount,
            address(0),
            1,
            feeBps,
            treasury,
            buyer,
            buyer
        );

        assertTrue(ok, "bond collection should succeed");
        assertEq(treasury.balance - treasuryEth0, expectedFee, "treasury should receive protocol fee");

        // Remaining ETH should have been forwarded to the incentive module call.
        assertEq(address(incentive).balance, expectedToRecord, "incentive module should receive net bond");
    }
}

