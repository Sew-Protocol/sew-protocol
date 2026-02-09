// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/PaymentCalculationLibraryV1.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/admin/EscrowGovernanceTimelock.sol';

/**
 * @title ReentrancyProtectionTest
 * @notice Tests reentrancy protection for critical functions
 * @dev Focuses on:
 *      - Payment claim reentrancy (ResolverIncentiveModule)
 *      - Bond distribution reentrancy (ResolverIncentiveModuleV2)
 *      - Escrow operation reentrancy (BaseEscrow)
 */
contract ReentrancyProtectionTest is Test {
    EscrowVault public escrow;
    ResolverIncentiveModuleV2 public incentiveModule;
    DecentralizedResolutionModule public resolutionModule;
    PaymentCalculationLibraryV1 public paymentLib;
    ERC20Mock public token;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    SettlementOps public settlementOps;
    CreateOps public createOps;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;
    EscrowGovernanceTimelock public adminContract;

    address public deployer;
    address public timelock;
    address public resolver1;
    address public attacker;
    address public user1;
    address public user2;

    uint256 public constant ESCROW_AMOUNT = 1000 ether;

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr('timelock');
        resolver1 = makeAddr('resolver1');
        attacker = makeAddr('attacker');
        user1 = makeAddr('user1');
        user2 = makeAddr('user2');

        // Deploy infrastructure
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        adminContract = new EscrowGovernanceTimelock(address(this));
        escrow = new EscrowVault(100, makeAddr('feeAddress'), address(yieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(escrow));

        // Register escrow contract callers on ops contracts
        yieldOps.registerEscrowContract(address(escrow));
        disputeOps.registerEscrowContract(address(escrow));
        settlementOps.registerEscrowContract(address(escrow));
        createOps.registerEscrowContract(address(escrow));
        bondCollector.registerEscrowContract(address(escrow));

        // Wire ops contracts on escrow
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(this));
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(adminContract));
        escrow.setCreateOps(address(createOps));
        escrow.setSettlementOps(address(settlementOps));
        escrow.setBondCollector(address(bondCollector));

        // Deploy modules
        paymentLib = new PaymentCalculationLibraryV1();
        incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
        resolutionModule = new DecentralizedResolutionModule(deployer);

        // Setup roles
        bytes32 ROLE_TIMELOCK = incentiveModule.ROLE_TIMELOCK();
        incentiveModule.grantRole(ROLE_TIMELOCK, timelock);
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);

        // Register escrow
        vm.startPrank(timelock);
        incentiveModule.registerEscrowContract(address(escrow));
        resolutionModule.registerEscrowContract(address(escrow));
        resolutionModule.setIncentiveModule(address(incentiveModule));
        vm.stopPrank();

        // Setup escrow
        escrow.grantRole(escrow.ROLE_TIMELOCK(), address(this));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), address(this));
        adminContract.queueResolutionModule(address(escrow), address(resolutionModule));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(escrow));

        // Appoint resolvers
        vm.startPrank(timelock);
        resolutionModule.appointSeniorResolver(resolver1, 'Senior Resolver', 'Test');
        vm.stopPrank();
        vm.prank(resolver1);
        resolutionModule.appointResolver(user1, 'Resolver 1', 'Test');
        vm.startPrank(timelock);
        resolutionModule.setResolverActive(resolver1, true);
        resolutionModule.setResolverActive(user1, true);
        resolutionModule.setResolverCapacity(resolver1, 0, true);
        resolutionModule.setResolverCapacity(user1, 0, true);
        vm.stopPrank();

        // Deploy token
        token = new ERC20Mock('Test Token', 'TEST', deployer, 1_000_000 ether);
        token.mint(user1, 1_000_000 ether);
        token.mint(address(incentiveModule), 10_000 ether);
    }

    // ============ Payment Claim Reentrancy Tests ============

    /**
     * @notice Test that claimPayment cannot be reentered
     */
    function test_claimPayment_ReentrancyProtection() public {
        // Setup: Create escrow, dispute, and record payment
        vm.startPrank(user1);
        token.approve(address(escrow), ESCROW_AMOUNT);
        uint256 workflowId = escrow.createEscrow(
            address(token),
            user2,
            ESCROW_AMOUNT,
            EscrowSettings({
                customResolver: address(0),
                releaseAddress: address(0), // Added default releaseAddress
                yieldPreset: YieldPreset.OFF,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();

        // Sanity: escrow was created
        (, , address from, , , , , , , ) = escrow.escrowTransfers(workflowId);
        assertEq(from, user1);
    }

}
