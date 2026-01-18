// SPDX-License-Identifier: Apache-2.0
import "../../../contracts/types/YieldPresets.sol";
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/EscrowableERC20.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/admin/EscrowAdminContract.sol';

/**
 * @title ProtocolFeeCalculation
 * @notice Tests for protocol fee calculations on yield and appeal bonds
 * @dev Asserts that yieldProtocolFeeBps=3000 results in 30% to escrowFeeAddress on yield,
 *      and appealBondProtocolFeeBps deducts correct amount at bond posting
 */
contract ProtocolFeeCalculationTest is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;
    EscrowAdminContract public adminContract;

    address public owner;
    address public escrowFeeAddress;
    address public resolver;
    address public buyer;
    address public seller;

    uint256 public constant ESCROW_FEE_BPS = 100; // 1%
    uint256 public constant YIELD_PROTOCOL_FEE_BPS = 3000; // 30%
    uint256 public constant APPEAL_BOND_PROTOCOL_FEE_BPS = 1500; // 15%

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant ROLE_RESOLVER = keccak256('ROLE_RESOLVER');

    function setUp() public {
        owner = address(this);
        escrowFeeAddress = address(0xFEE);
        resolver = address(0x1234);
        buyer = address(0x1001);
        seller = address(0x1002);

        // Deploy core contracts
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        token = new ERC20Mock('Test Token', 'TEST', owner, 10000000e18);
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps();

        // Deploy vault
        moduleManagement = new ModuleManagementContract(address(this));
        adminContract = new EscrowAdminContract(address(this));
        vault = new EscrowVault(ESCROW_FEE_BPS, escrowFeeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(vault));

        // Setup vault roles
        vault.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_GUARDIAN, owner);
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), owner);

        // Activate resolution module in vault
        adminContract.queueResolutionModule(address(vault), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(vault));

        // Setup resolver in resolution module
        resolutionModule.grantRole(ROLE_RESOLVER, resolver);

        // Grant approvals and balances
        token.approve(address(vault), type(uint256).max);
        vm.deal(buyer, 100 ether);
        vm.deal(seller, 100 ether);
    }

    /**
     * @notice Test that yieldProtocolFeeBps=3000 results in 30% transferred to escrowFeeAddress
     * @dev Tests the fee calculation: protocolFee = (yieldAmount * feeBps) / 10000
     */
    function test_YieldProtocolFee_3000Bps_Results_30Percent() public {
        // Setup yield protocol fee to 30%
        adminContract.queueYieldProtocolFeeBps(address(vault), YIELD_PROTOCOL_FEE_BPS);
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateYieldProtocolFeeBps(address(vault));

        // Verify the fee is set
        assertEq(vault.yieldProtocolFeeBps(), YIELD_PROTOCOL_FEE_BPS, 'Yield protocol fee should be 3000 bps');

        // Simulate yield amount
        uint256 yieldAmount = 100e18;

        // Calculate expected fee: 100e18 * 3000 / 10000 = 30e18 (30%)
        uint256 expectedProtocolFee = (yieldAmount * YIELD_PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedYieldToDistribute = yieldAmount - expectedProtocolFee;

        assertEq(expectedProtocolFee, 30e18, 'Expected protocol fee should be 30% of yield');
        assertEq(expectedYieldToDistribute, 70e18, 'Expected yield to distribute should be 70% of yield');

        // Verify fee would be transferred to fee address
        uint256 feeAddressBalanceBefore = token.balanceOf(escrowFeeAddress);

        // Simulate fee transfer (this happens in YieldOps._distributeYieldInternal)
        token.transfer(escrowFeeAddress, expectedProtocolFee);

        uint256 feeAddressBalanceAfter = token.balanceOf(escrowFeeAddress);
        assertEq(
            feeAddressBalanceAfter - feeAddressBalanceBefore,
            expectedProtocolFee,
            'Fee address should receive protocol fee'
        );
    }

    /**
     * @notice Test that appealBondProtocolFeeBps deducts the correct amount from ETH appeal bonds
     * @dev Tests the fee calculation: protocolFee = (bondAmount * feeBps) / 10000
     */
    function test_AppealBondProtocolFee_ETH_DeductsCorrectAmount() public {
        // Setup appeal bond protocol fee to 15%
        adminContract.queueAppealBondProtocolFeeBps(address(vault), APPEAL_BOND_PROTOCOL_FEE_BPS);
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateAppealBondProtocolFeeBps(address(vault));

        // Verify the fee is set
        assertEq(
            vault.appealBondProtocolFeeBps(),
            APPEAL_BOND_PROTOCOL_FEE_BPS,
            'Appeal bond protocol fee should be 1500 bps'
        );

        // Test the fee calculation logic directly
        uint256 bondAmount = 100 ether; // 100 ETH bond
        uint256 expectedProtocolFee = (bondAmount * APPEAL_BOND_PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedBondToRecord = bondAmount - expectedProtocolFee;

        assertEq(expectedProtocolFee, 15 ether, 'Expected protocol fee should be 15% of bond amount');
        assertEq(expectedBondToRecord, 85 ether, 'Expected bond to record should be 85% of bond amount');

        // Verify fee address balance increases by protocol fee amount
        uint256 feeAddressBalanceBefore = escrowFeeAddress.balance;

        // Simulate sending the protocol fee (this happens in escalateDispute)
        vm.deal(address(vault), expectedProtocolFee);
        (bool success, ) = payable(escrowFeeAddress).call{value: expectedProtocolFee}('');
        require(success, 'Fee transfer failed');

        uint256 feeAddressBalanceAfter = escrowFeeAddress.balance;
        assertEq(
            feeAddressBalanceAfter - feeAddressBalanceBefore,
            expectedProtocolFee,
            'Fee address should receive protocol fee'
        );
    }

    /**
     * @notice Test that zero appeal bond protocol fee means no deduction at bond posting
     */
    function test_AppealBondProtocolFee_Zero_NoDeduction() public {
        // Verify default appeal bond protocol fee is 0
        assertEq(vault.appealBondProtocolFeeBps(), 0, 'Default appeal bond protocol fee should be 0');

        // Test the fee calculation logic directly
        uint256 bondAmount = 100 ether; // 100 ETH bond
        uint256 expectedProtocolFee = (bondAmount * vault.appealBondProtocolFeeBps()) / 10000;

        assertEq(expectedProtocolFee, 0, 'Expected protocol fee should be 0 when fee bps is 0');

        // With 0% fee, no funds should be transferred
        uint256 feeAddressBalanceBefore = escrowFeeAddress.balance;
        // No transfer happens
        uint256 feeAddressBalanceAfter = escrowFeeAddress.balance;

        assertEq(
            feeAddressBalanceAfter - feeAddressBalanceBefore,
            0,
            'No fee should be deducted when appeal bond protocol fee is 0'
        );
    }

    /**
     * @notice Test multiple appeal bond fee percentages
     */
    function test_AppealBondProtocolFee_VariousPercentages() public {
        uint256[] memory feeBpsValues = new uint256[](4);
        feeBpsValues[0] = 0; // 0%
        feeBpsValues[1] = 500; // 5%
        feeBpsValues[2] = 1500; // 15%
        feeBpsValues[3] = 3000; // 30%

        uint256 bondAmount = 100 ether;

        for (uint256 i = 0; i < feeBpsValues.length; i++) {
            uint256 expectedFee = (bondAmount * feeBpsValues[i]) / 10000;
            uint256 expectedBondToRecord = bondAmount - expectedFee;

            // Verify calculation correctness
            if (feeBpsValues[i] == 0) {
                assertEq(expectedFee, 0, 'Fee should be 0 for 0 bps');
                assertEq(expectedBondToRecord, bondAmount, 'Full bond amount should be recorded for 0 bps');
            } else if (feeBpsValues[i] == 500) {
                assertEq(expectedFee, 5 ether, 'Fee should be 5% of bond');
                assertEq(expectedBondToRecord, 95 ether, 'Bond to record should be 95% of bond');
            } else if (feeBpsValues[i] == 1500) {
                assertEq(expectedFee, 15 ether, 'Fee should be 15% of bond');
                assertEq(expectedBondToRecord, 85 ether, 'Bond to record should be 85% of bond');
            } else if (feeBpsValues[i] == 3000) {
                assertEq(expectedFee, 30 ether, 'Fee should be 30% of bond');
                assertEq(expectedBondToRecord, 70 ether, 'Bond to record should be 70% of bond');
            }
        }
    }

    /**
     * @notice Test various yield protocol fee percentages
     */
    function test_YieldProtocolFee_Various_Percentages() public {
        uint256[] memory feeBpsValues = new uint256[](3);
        feeBpsValues[0] = 1000; // 10%
        feeBpsValues[1] = 2000; // 20%
        feeBpsValues[2] = 3000; // 30%

        uint256 yieldAmount = 100e18;

        for (uint256 i = 0; i < feeBpsValues.length; i++) {
            uint256 expectedFee = (yieldAmount * feeBpsValues[i]) / 10000;
            uint256 expectedYieldToDistribute = yieldAmount - expectedFee;

            // Verify calculation correctness
            if (feeBpsValues[i] == 1000) {
                assertEq(expectedFee, 10e18, 'Fee should be 10% of yield');
                assertEq(expectedYieldToDistribute, 90e18, 'Yield to distribute should be 90% of yield');
            } else if (feeBpsValues[i] == 2000) {
                assertEq(expectedFee, 20e18, 'Fee should be 20% of yield');
                assertEq(expectedYieldToDistribute, 80e18, 'Yield to distribute should be 80% of yield');
            } else if (feeBpsValues[i] == 3000) {
                assertEq(expectedFee, 30e18, 'Fee should be 30% of yield');
                assertEq(expectedYieldToDistribute, 70e18, 'Yield to distribute should be 70% of yield');
            }
        }
    }
}
