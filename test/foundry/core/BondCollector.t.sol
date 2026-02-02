// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/decentralized-resolution-module/IIncentiveModule.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/**
 * @title BondCollectorTest
 * @notice Comprehensive tests for BondCollector covering all functions and code paths
 * @dev Goal: 99% coverage for BondCollector.sol
 * 
 * Following strategy from 99_PERCENT_TEST_COVERAGE_STRATEGY.md:
 * - All public/external functions (success + key reverts)
 * - ETH bond collection with protocol fee
 * - ERC20 bond collection with protocol fee
 * - Access control (ROLE_ESCROW_CONTRACT, ROLE_TIMELOCK)
 * - Edge cases (zero amounts, zero fees, failed transfers)
 */
contract BondCollectorTest is Test {
    BondCollector public bondCollector;
    ERC20Mock public token;
    MockIncentiveModule public incentiveModule;
    
    address public owner;
    address public timelock;
    address public escrowContract;
    address public feeAddress;
    address public unauthorized;
    address public user;
    
    uint256 public constant BOND_AMOUNT = 1000e18;
    uint256 public constant PROTOCOL_FEE_BPS = 500; // 5%
    
    function setUp() public {
        owner = address(this);
        timelock = address(0x1111);
        escrowContract = address(0x2222);
        feeAddress = address(0xFEE);
        unauthorized = address(0x9999);
        user = address(0xAAAA);
        
        bondCollector = new BondCollector(owner);
        token = new ERC20Mock('Test Token', 'TEST', owner, 10000000e18);
        incentiveModule = new MockIncentiveModule();
        
        // Setup roles
        bondCollector.grantRole(bondCollector.ROLE_TIMELOCK(), timelock);
        bondCollector.grantRole(bondCollector.ROLE_ESCROW_CONTRACT(), escrowContract);
    }
    
    // ============ Constructor Tests ============
    
    function test_constructor_setsOwner() public {
        BondCollector newCollector = new BondCollector(owner);
        assertTrue(newCollector.hasRole(newCollector.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(newCollector.hasRole(newCollector.ROLE_TIMELOCK(), owner));
    }
    
    function test_constructor_zeroOwner_reverts() public {
        vm.expectRevert(BondCollector.ZeroOwner.selector);
        new BondCollector(address(0));
    }
    
    // ============ registerEscrowContract Tests ============
    
    function test_registerEscrowContract_success() public {
        address newEscrow = address(0x3333);
        vm.prank(timelock);
        bondCollector.registerEscrowContract(newEscrow);
        assertTrue(bondCollector.hasRole(bondCollector.ROLE_ESCROW_CONTRACT(), newEscrow));
    }
    
    function test_registerEscrowContract_zeroAddress_reverts() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector, ADDR_ESCROW_CONTRACT, address(0)));
        bondCollector.registerEscrowContract(address(0));
    }
    
    function test_registerEscrowContract_unauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        bondCollector.registerEscrowContract(address(0x3333));
    }
    
    // ============ collectBond ETH Tests ============
    
    function test_collectBond_ETH_success_noFee() public {
        uint256 bondAmount = 1 ether;
        vm.deal(escrowContract, bondAmount);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond{value: bondAmount}(
            1,
            incentiveModule,
            bondAmount,
            address(0), // ETH
            1, // newLevel
            0, // no protocol fee
            feeAddress,
            user, // depositor
            user  // escalatedBy
        );
        
        assertTrue(collected);
        assertEq(address(incentiveModule).balance, bondAmount);
        assertEq(escrowContract.balance, 0);
    }
    
    function test_collectBond_ETH_success_withFee() public {
        uint256 bondAmount = 1 ether;
        uint256 expectedFee = (bondAmount * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedToModule = bondAmount - expectedFee;
        
        vm.deal(escrowContract, bondAmount);
        
        // Expect event before the call
        vm.expectEmit(true, true, true, true);
        emit BondCollector.ProtocolFeeCollected(1, 1, address(0), bondAmount, PROTOCOL_FEE_BPS, expectedFee);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond{value: bondAmount}(
            1,
            incentiveModule,
            bondAmount,
            address(0),
            1,
            PROTOCOL_FEE_BPS,
            feeAddress,
            user,
            user
        );
        
        assertTrue(collected);
        assertEq(feeAddress.balance, expectedFee);
        assertEq(address(incentiveModule).balance, expectedToModule);
    }
    
    function test_collectBond_ETH_excessValue() public {
        uint256 bondAmount = 1 ether;
        uint256 sentValue = 2 ether;
        vm.deal(escrowContract, sentValue);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond{value: sentValue}(
            1,
            incentiveModule,
            bondAmount,
            address(0),
            1,
            0,
            feeAddress,
            user,
            user
        );
        
        assertTrue(collected);
        assertEq(address(incentiveModule).balance, bondAmount);
        // Excess ETH remains with BondCollector (not refunded)
    }
    
    function test_collectBond_ETH_zeroIncentiveModule() public {
        uint256 bondAmount = 1 ether;
        vm.deal(escrowContract, bondAmount);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond{value: bondAmount}(
            1,
            IIncentiveModule(address(0)),
            bondAmount,
            address(0),
            1,
            0,
            feeAddress,
            user,
            user
        );
        
        assertFalse(collected);
    }
    
    function test_collectBond_ETH_feeTransferFails() public {
        uint256 bondAmount = 1 ether;
        vm.deal(escrowContract, bondAmount);
        
        // Create a contract that rejects ETH
        RevertingReceiver receiver = new RevertingReceiver();
        feeAddress = address(receiver);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond{value: bondAmount}(
            1,
            incentiveModule,
            bondAmount,
            address(0),
            1,
            PROTOCOL_FEE_BPS,
            feeAddress,
            user,
            user
        );
        
        assertFalse(collected);
    }
    
    function test_collectBond_ETH_moduleCallFails() public {
        uint256 bondAmount = 1 ether;
        vm.deal(escrowContract, bondAmount);
        
        incentiveModule.setRevert(true);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond{value: bondAmount}(
            1,
            incentiveModule,
            bondAmount,
            address(0),
            1,
            0,
            feeAddress,
            user,
            user
        );
        
        assertFalse(collected);
    }
    
    function test_collectBond_ETH_unauthorized_reverts() public {
        // Access control check happens before ETH transfer, so we don't need to send ETH
        vm.prank(unauthorized);
        vm.expectRevert();
        bondCollector.collectBond(
            1,
            incentiveModule,
            1 ether,
            address(0),
            1,
            0,
            feeAddress,
            user,
            user
        );
    }
    
    // ============ collectBond ERC20 Tests ============
    
    function test_collectBond_ERC20_success_noFee() public {
        uint256 bondAmount = 1000e18;
        token.transfer(escrowContract, bondAmount);
        vm.prank(escrowContract);
        token.approve(address(bondCollector), bondAmount);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond(
            1,
            incentiveModule,
            bondAmount,
            address(token),
            1,
            0, // no fee
            feeAddress,
            address(bondCollector), // depositor (this contract for ERC20)
            user  // escalatedBy
        );
        
        assertTrue(collected);
        assertEq(token.balanceOf(address(incentiveModule)), bondAmount);
        assertEq(token.balanceOf(address(bondCollector)), 0);
    }
    
    function test_collectBond_ERC20_success_withFee() public {
        uint256 bondAmount = 1000e18;
        uint256 expectedFee = (bondAmount * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedToModule = bondAmount - expectedFee;
        
        token.transfer(escrowContract, bondAmount);
        vm.prank(escrowContract);
        token.approve(address(bondCollector), bondAmount);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond(
            1,
            incentiveModule,
            bondAmount,
            address(token),
            1,
            PROTOCOL_FEE_BPS,
            feeAddress,
            address(bondCollector),
            user
        );
        
        assertTrue(collected);
        assertEq(token.balanceOf(feeAddress), expectedFee);
        assertEq(token.balanceOf(address(incentiveModule)), expectedToModule);
        assertEq(token.balanceOf(address(bondCollector)), 0);
    }
    
    function test_collectBond_ERC20_zeroFeeAddress() public {
        uint256 bondAmount = 1000e18;
        token.transfer(escrowContract, bondAmount);
        vm.prank(escrowContract);
        token.approve(address(bondCollector), bondAmount);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond(
            1,
            incentiveModule,
            bondAmount,
            address(token),
            1,
            PROTOCOL_FEE_BPS,
            address(0), // zero fee address
            address(bondCollector),
            user
        );
        
        assertTrue(collected);
        // No fee transferred, all goes to module
        assertEq(token.balanceOf(address(incentiveModule)), bondAmount);
    }
    
    function test_collectBond_ERC20_moduleCallFails() public {
        uint256 bondAmount = 1000e18;
        token.transfer(escrowContract, bondAmount);
        vm.prank(escrowContract);
        token.approve(address(bondCollector), bondAmount);
        
        incentiveModule.setRevert(true);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond(
            1,
            incentiveModule,
            bondAmount,
            address(token),
            1,
            0,
            feeAddress,
            address(bondCollector),
            user
        );
        
        assertFalse(collected);
        // Approval should be reset
        assertEq(token.allowance(address(bondCollector), address(incentiveModule)), 0);
    }
    
    function test_collectBond_ERC20_zeroIncentiveModule() public {
        uint256 bondAmount = 1000e18;
        token.transfer(escrowContract, bondAmount);
        vm.prank(escrowContract);
        token.approve(address(bondCollector), bondAmount);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond(
            1,
            IIncentiveModule(address(0)),
            bondAmount,
            address(token),
            1,
            0,
            feeAddress,
            address(bondCollector),
            user
        );
        
        assertFalse(collected);
    }
    
    function test_collectBond_ERC20_zeroBondAmount() public {
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond(
            1,
            incentiveModule,
            0,
            address(token),
            1,
            0,
            feeAddress,
            address(bondCollector),
            user
        );
        
        assertFalse(collected);
    }
    
    // ============ approveBondSpender Tests ============
    
    function test_approveBondSpender_success() public {
        uint256 amount = 1000e18;
        token.transfer(address(bondCollector), amount);
        
        uint256 allowanceBefore = token.allowance(address(bondCollector), address(incentiveModule));
        
        vm.prank(escrowContract);
        bondCollector.approveBondSpender(address(token), address(incentiveModule), amount);
        
        uint256 allowanceAfter = token.allowance(address(bondCollector), address(incentiveModule));
        assertEq(allowanceAfter, allowanceBefore + amount);
    }
    
    function test_approveBondSpender_unauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        bondCollector.approveBondSpender(address(token), address(incentiveModule), 1000e18);
    }
    
    // ============ resetBondSpender Tests ============
    
    function test_resetBondSpender_success() public {
        uint256 amount = 1000e18;
        token.transfer(address(bondCollector), amount);
        
        // First approve
        vm.prank(escrowContract);
        bondCollector.approveBondSpender(address(token), address(incentiveModule), amount);
        assertGt(token.allowance(address(bondCollector), address(incentiveModule)), 0);
        
        // Then reset
        vm.prank(escrowContract);
        bondCollector.resetBondSpender(address(token), address(incentiveModule));
        assertEq(token.allowance(address(bondCollector), address(incentiveModule)), 0);
    }
    
    function test_resetBondSpender_unauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        bondCollector.resetBondSpender(address(token), address(incentiveModule));
    }
    
    // ============ Edge Cases ============
    
    function test_collectBond_ETH_maxFee() public {
        uint256 bondAmount = 1 ether;
        uint256 maxFeeBps = 3000; // 30%
        uint256 expectedFee = (bondAmount * maxFeeBps) / 10000;
        
        vm.deal(escrowContract, bondAmount);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond{value: bondAmount}(
            1,
            incentiveModule,
            bondAmount,
            address(0),
            1,
            maxFeeBps,
            feeAddress,
            user,
            user
        );
        
        assertTrue(collected);
        assertEq(feeAddress.balance, expectedFee);
    }
    
    function test_collectBond_ERC20_rounding() public {
        // Test with amount that causes rounding
        uint256 bondAmount = 1001; // Small amount
        uint256 feeBps = 333; // 3.33%
        token.transfer(escrowContract, bondAmount);
        vm.prank(escrowContract);
        token.approve(address(bondCollector), bondAmount);
        
        vm.prank(escrowContract);
        bool collected = bondCollector.collectBond(
            1,
            incentiveModule,
            bondAmount,
            address(token),
            1,
            feeBps,
            feeAddress,
            address(bondCollector),
            user
        );
        
        assertTrue(collected);
        // Fee should be rounded down
        uint256 fee = token.balanceOf(feeAddress);
        uint256 toModule = token.balanceOf(address(incentiveModule));
        assertEq(fee + toModule, bondAmount);
    }
}

// ============ Mocks ============

contract MockIncentiveModule is IIncentiveModule {
    using SafeERC20 for IERC20;
    
    bool public shouldRevert;
    
    function setRevert(bool _r) external {
        shouldRevert = _r;
    }
    
    function recordAppealBond(
        uint256,
        address depositor,
        address,
        uint256 amount,
        address token,
        uint8
    ) external payable {
        if (shouldRevert) revert("Mock revert");
        // Accept ETH (received via msg.value) or pull ERC20 tokens
        if (token != address(0)) {
            // ERC20: pull tokens from depositor (BondCollector)
            IERC20(token).safeTransferFrom(depositor, address(this), amount);
        }
        // ETH is received via msg.value automatically
    }
    
    // Required interface functions (stubs)
    function onDisputeOpened(uint256, address, uint256, uint256, uint8) external {}
    function onResolverAssigned(uint256, address, uint8) external {}
    function onDecisionSubmitted(
        uint256,
        address,
        uint8,
        DecentralizedResolverStructs.ResolutionOutcome,
        uint256
    ) external {}
    function onEscalated(uint256, uint8, uint8, address) external {}
    function onDisputeFinalized(
        uint256,
        uint8,
        DecentralizedResolverStructs.ResolutionOutcome
    ) external {}
    function onResolverTimeout(uint256, address, uint8, uint8) external {}
    function distributePayments(uint256, address, uint256) external {}
    function getClaimablePayment(uint256, address) external pure returns (uint256) {
        return 0;
    }
    function supportsFeature(bytes4) external pure returns (bool) {
        return false;
    }
    function getRequiredAppealBond(uint256, uint8, uint8) external pure returns (uint256, address) {
        return (0, address(0));
    }
    function distributeAppealBond(uint256, uint8, bool) external {}
}

contract RevertingReceiver {
    receive() external payable {
        revert("Reject ETH");
    }
}
