// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV1.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';

import '../../../contracts/core/ModuleSnapshotRegistry.sol';
/**
 * @title AppealBondRecordingTest
 * @notice Unit tests for recordAppealBond functionality
 * @dev Tests appeal bond recording with various parameters and edge cases
 */
contract AppealBondRecordingTest is Test {
    ResolverIncentiveModuleV2 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    EscrowVault public escrow;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public moduleManagement;

    address public deployer;
    address public depositor;
    address public timelock;
    address public feeAddress;

    uint256 public constant INITIAL_BALANCE = 10000 ether;
    uint256 public constant WORKFLOW_ID = 0;

    function setUp() public {
        deployer = address(this);
        depositor = makeAddr('depositor');
        timelock = makeAddr('timelock');
        feeAddress = makeAddr('feeAddress');

        // Deploy contracts
        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
        token = new ERC20Mock('Test Token', 'TEST', address(this), 0);
        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), address(this));
        incentiveModule.registerEscrowContract(address(this));
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        escrow = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        // Setup tokens
        token.mint(depositor, INITIAL_BALANCE);

        // Grant roles
        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), timelock);

        // Register escrow contract
        vm.prank(timelock);
        incentiveModule.registerEscrowContract(address(escrow));
    }

    /**
     * @notice Test basic appeal bond recording
     */
    function test_recordAppealBond_Success() public {
        uint256 amount = 1 ether;
        uint8 round = 1;

        // Prepare tokens - approve incentive module (pull-based pattern)
        vm.prank(depositor);
        token.approve(address(incentiveModule), amount);

        // Record bond - incentive module will pull tokens from depositor
        vm.prank(address(this));
        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), depositor, depositor, amount, address(token), round);

        // Verify bond recorded
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModule.getAppealBond(
            WORKFLOW_ID,
            address(this),
            round
        );
        uint256 bondAmount = bond.amount;
        assertEq(bondAmount, amount, 'Bond amount should match');
    }

    /**
     * @notice Test ETH bond recording
     */
    function test_recordAppealBond_ETHBond() public {
        uint256 amount = 1 ether;
        uint8 round = 1;

        // Send ETH to escrow contract (which will call recordAppealBond)
        vm.deal(address(escrow), amount);

        // Record bond - function is now payable and requires msg.value == amount
        vm.prank(address(this));
        incentiveModule.recordAppealBond{value: amount}(
            WORKFLOW_ID,
            address(this),
            depositor,
            depositor,
            amount,
            address(0),
            round
        );

        // Verify bond recorded
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModule.getAppealBond(
            WORKFLOW_ID,
            address(this),
            round
        );
        uint256 bondAmount = bond.amount;
        assertEq(bondAmount, amount, 'ETH bond amount should match');
    }

    /**
     * @notice Test ERC20 bond recording
     */
    function test_recordAppealBond_ERC20Bond() public {
        uint256 amount = 1000e18;
        uint8 round = 2;

        // Prepare tokens - approve incentive module (pull-based pattern)
        vm.prank(depositor);
        token.approve(address(incentiveModule), amount);

        // Record bond - incentive module will pull tokens from depositor
        vm.prank(address(this));
        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), depositor, depositor, amount, address(token), round);

        // Verify bond recorded
        ResolverIncentiveModuleV2.AppealBondRecord memory bond = incentiveModule.getAppealBond(
            WORKFLOW_ID,
            address(this),
            round
        );
        uint256 bondAmount = bond.amount;
        assertEq(bondAmount, amount, 'ERC20 bond amount should match');
    }

    /**
     * @notice Test duplicate bond prevention
     */
    function test_recordAppealBond_PreventDuplicate() public {
        uint256 amount = 1 ether;
        uint8 round = 1;

        // Prepare tokens - approve incentive module
        vm.prank(depositor);
        token.approve(address(incentiveModule), amount * 2);

        // Record first bond
        vm.prank(address(this));
        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), depositor, depositor, amount, address(token), round);

        // Try to record duplicate (should revert)
        vm.prank(address(this));
        vm.expectRevert('Bond already exists');
        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), depositor, depositor, amount, address(token), round);
    }

    /**
     * @notice Test invalid round 0 (bonds only for rounds 1-2)
     */
    function test_recordAppealBond_InvalidRoundZero() public {
        uint256 amount = 1 ether;
        uint8 round = 0;
        vm.prank(address(this));
        vm.expectRevert('Invalid round');
        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), depositor, depositor, amount, address(token), round);
    }

    /**
     * @notice Test invalid round > 2
     */
    function test_recordAppealBond_InvalidRoundTooHigh() public {
        uint256 amount = 1 ether;
        uint8 round = 3;

        vm.prank(address(this));
        vm.expectRevert('Invalid round');
        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), depositor, depositor, amount, address(token), round);
    }

    /**
     * @notice Test zero amount rejection
     */
    function test_recordAppealBond_ZeroAmount() public {
        uint256 amount = 0;
        uint8 round = 1;

        vm.prank(address(this));
        vm.expectRevert('Invalid amount');
        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), depositor, depositor, amount, address(token), round);
    }

    /**
     * @notice Test zero depositor rejection
     */
    function test_recordAppealBond_ZeroDepositor() public {
        uint256 amount = 1 ether;
        uint8 round = 1;

        // Call from non-escrow address
        vm.prank(address(this));
        vm.expectRevert('Invalid depositor');
        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), address(0), address(0), amount, address(token), round);
    }

    /**
     * @notice Test non-escrow caller rejection
     */
    function test_recordAppealBond_NotEscrowContract() public {
        uint256 amount = 1 ether;
        uint8 round = 1;

        vm.prank(depositor);
        token.approve(address(incentiveModule), amount);

        // Call from non-escrow address
        address nonEscrow = makeAddr('nonEscrow');
        vm.prank(nonEscrow);
        vm.expectRevert(
            abi.encodeWithSignature(
                "NotRegisteredEscrowContract(address)",
                nonEscrow
            )
        );
        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), depositor, depositor, amount, address(token), round);
    }

    /**
     * @notice Test event emission on successful record
     */
    function test_recordAppealBond_EventEmitted() public {
        uint256 amount = 1 ether;
        uint8 round = 1;

        vm.prank(depositor);
        token.approve(address(incentiveModule), amount);

        vm.prank(address(this));
        vm.expectEmit(true, true, true, true);
        emit AppealBondRecorded(WORKFLOW_ID, round, depositor, amount, address(token));

        incentiveModule.recordAppealBond(WORKFLOW_ID, address(this), depositor, depositor, amount, address(token), round);
    }

    event AppealBondRecorded(
        uint256 indexed escrowId,
        uint8 round,
        address indexed depositor,
        uint256 amount,
        address token
    );
}
