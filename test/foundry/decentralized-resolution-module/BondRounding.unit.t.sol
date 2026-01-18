// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';

import '../../../contracts/core/ModuleManagementContract.sol';
/**
 * @title BondRoundingTest
 * @notice Tests for rounding error handling in bond distribution
 * @dev Ensures no wei is lost when distributing bonds among resolvers
 */
contract BondRoundingTest is Test {
    ResolverIncentiveModuleV2 public incentiveModule;
    PaymentCalculationLibraryV1 public paymentLib;
    EscrowVault public escrow;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;

    address public deployer;
    address public timelock;
    address public feeAddress;
    address[] public resolvers;

    uint256 public constant INITIAL_BALANCE = 10000 ether;

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        feeAddress = makeAddr('feeAddress');

        // Deploy contracts
        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
        token = new ERC20Mock('Test Token', 'TEST', address(this), 0);
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        escrow = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        // Grant roles
        incentiveModule.grantRole(incentiveModule.ROLE_TIMELOCK(), timelock);

        // Register escrow contract
        vm.prank(timelock);
        incentiveModule.registerEscrowContract(address(escrow));
    }

    /**
     * @notice Helper to create resolvers
     */
    function _createResolvers(uint8 count) internal {
        for (uint8 i = 0; i < count; i++) {
            resolvers.push(makeAddr(string(abi.encodePacked('resolver', i))));
        }
    }

    /**
     * @notice Helper to record resolvers for a workflow
     */
    function _recordResolvers(uint256 workflowId, uint8 round, uint256 resolverCount) internal {
        for (uint256 i = 0; i < resolverCount; i++) {
            vm.prank(address(escrow));
            incentiveModule.recordResolver(workflowId, resolvers[i], round);
        }
    }

    /**
     * @notice Test 3 resolvers, 100 wei bond - verify no rounding loss
     */
    function test_BondDistribution_Rounding_3Resolvers_100Wei() public {
        _createResolvers(3);

        uint256 workflowId = 0;
        uint256 bondAmount = 100;

        // Setup bond - mint to depositor and approve
        address depositor = makeAddr('depositor');
        token.mint(depositor, bondAmount);
        
        vm.prank(depositor);
        token.approve(address(incentiveModule), bondAmount);

        vm.prank(address(escrow));
        incentiveModule.recordAppealBond(workflowId, depositor, depositor, bondAmount, address(token), 1);

        // Record resolvers at round 0
        _recordResolvers(workflowId, 0, 3);

        // Distribute bond on failed appeal
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(workflowId, 0, false);

        // Verify no rounding loss
        uint256 resolver1Payment = incentiveModule.getClaimablePayment(workflowId, resolvers[0]);
        uint256 resolver2Payment = incentiveModule.getClaimablePayment(workflowId, resolvers[1]);
        uint256 resolver3Payment = incentiveModule.getClaimablePayment(workflowId, resolvers[2]);

        uint256 total = resolver1Payment + resolver2Payment + resolver3Payment;
        assertEq(total, bondAmount, 'Total distributed should equal 100');

        // Verify proper distribution (33-34 split)
        assertGe(resolver1Payment, 33, 'Min payment should be 33');
        assertLe(resolver1Payment, 34, 'Max payment should be 34');
        assertGe(resolver2Payment, 33, 'Min payment should be 33');
        assertLe(resolver2Payment, 34, 'Max payment should be 34');
        assertGe(resolver3Payment, 33, 'Min payment should be 33');
        assertLe(resolver3Payment, 34, 'Max payment should be 34');
    }

    /**
     * @notice Test 5 resolvers, 99 wei bond - verify no rounding loss
     */
    function test_BondDistribution_Rounding_5Resolvers_99Wei() public {
        _createResolvers(5);

        uint256 workflowId = 1;
        uint256 bondAmount = 99;

        // Setup bond - mint to depositor and approve
        address depositor = makeAddr('depositor');
        token.mint(depositor, bondAmount);
        
        vm.prank(depositor);
        token.approve(address(incentiveModule), bondAmount);

        vm.prank(address(escrow));
        incentiveModule.recordAppealBond(workflowId, depositor, depositor, bondAmount, address(token), 1);

        // Record resolvers at round 0
        _recordResolvers(workflowId, 0, 5);

        // Distribute bond
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(workflowId, 0, false);

        // Verify no rounding loss
        uint256 total = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 payment = incentiveModule.getClaimablePayment(workflowId, resolvers[i]);
            total += payment;
            assertGe(payment, 19, 'Min payment should be 19');
            assertLe(payment, 20, 'Max payment should be 20');
        }

        assertEq(total, bondAmount, 'Total distributed should equal 99');
    }

    /**
     * @notice Test 2 resolvers, 100 wei bond - even division
     */
    function test_BondDistribution_EvenDivision() public {
        _createResolvers(2);

        uint256 workflowId = 2;
        uint256 bondAmount = 100;

        // Setup bond - mint to depositor and approve
        address depositor = makeAddr('depositor');
        token.mint(depositor, bondAmount);
        
        vm.prank(depositor);
        token.approve(address(incentiveModule), bondAmount);

        vm.prank(address(escrow));
        incentiveModule.recordAppealBond(workflowId, depositor, depositor, bondAmount, address(token), 1);

        // Record resolvers at round 0
        _recordResolvers(workflowId, 0, 2);

        // Distribute bond
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(workflowId, 0, false);

        // Verify equal split
        uint256 resolver1Payment = incentiveModule.getClaimablePayment(workflowId, resolvers[0]);
        uint256 resolver2Payment = incentiveModule.getClaimablePayment(workflowId, resolvers[1]);

        assertEq(resolver1Payment, 50, 'Resolver 1 should get 50');
        assertEq(resolver2Payment, 50, 'Resolver 2 should get 50');
    }

    /**
     * @notice Test single resolver gets entire bond
     */
    function test_BondDistribution_SingleResolver() public {
        _createResolvers(1);

        uint256 workflowId = 3;
        uint256 bondAmount = 123456;

        // Setup bond - mint to depositor and approve
        address depositor = makeAddr('depositor');
        token.mint(depositor, bondAmount);
        
        vm.prank(depositor);
        token.approve(address(incentiveModule), bondAmount);

        vm.prank(address(escrow));
        incentiveModule.recordAppealBond(workflowId, depositor, depositor, bondAmount, address(token), 1);

        // Record resolver at round 0
        _recordResolvers(workflowId, 0, 1);

        // Distribute bond
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(workflowId, 0, false);

        // Verify resolver gets entire bond
        uint256 resolverPayment = incentiveModule.getClaimablePayment(workflowId, resolvers[0]);
        assertEq(resolverPayment, bondAmount, 'Single resolver should get entire bond');
    }

    /**
     * @notice Fuzz test: no rounding loss with variable amounts and resolvers
     */
    function testFuzz_BondDistribution_NoLoss(uint256 bondAmount, uint8 resolverCount) public {
        // Constrain inputs
        bondAmount = bound(bondAmount, 1, 1000 ether);
        resolverCount = uint8(bound(resolverCount, 1, 10));

        // Create resolvers
        for (uint8 i = 0; i < resolverCount; i++) {
            resolvers.push(makeAddr(string(abi.encodePacked('r', i))));
        }

        uint256 workflowId = uint256(keccak256(abi.encode(bondAmount, resolverCount)));

        // Setup bond - mint to depositor and approve
        address depositor = makeAddr('depositor');
        token.mint(depositor, bondAmount);
        
        vm.prank(depositor);
        token.approve(address(incentiveModule), bondAmount);

        vm.prank(address(escrow));
        incentiveModule.recordAppealBond(workflowId, depositor, depositor, bondAmount, address(token), 1);

        // Record resolvers
        for (uint8 i = 0; i < resolverCount; i++) {
            vm.prank(address(escrow));
            incentiveModule.recordResolver(workflowId, resolvers[i], 0);
        }

        // Distribute bond
        vm.prank(address(escrow));
        incentiveModule.distributeAppealBond(workflowId, 0, false);

        // Verify no rounding loss
        uint256 total = 0;
        for (uint8 i = 0; i < resolverCount; i++) {
            uint256 payment = incentiveModule.getClaimablePayment(workflowId, resolvers[i]);
            total += payment;
        }

        assertEq(total, bondAmount, 'Total distributed should equal bond amount (no loss)');
    }
}
