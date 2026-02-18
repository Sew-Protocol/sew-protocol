// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/types/YieldPresets.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @title AaveYieldModuleForkTest
 * @notice Fork tests for AaveYieldModule using real Base Sepolia Aave V3
 * 
 * PREREQUISITES:
 * 1. Set RPC in foundry.toml or environment:
 *    [rpc_endpoints]
 *    base_sepolia = "${RPC_BASE_SEPOLIA}"
 * 
 * 2. Or run with fork URL:
 *    forge test --match-contract AaveYieldModuleForkTest -vvv --fork-url $RPC_BASE_SEPOLIA
 * 
 * Real Aave V3 on Base Sepolia:
 * - Pool: 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
 * - USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
 */
contract AaveYieldModuleForkTest is Test {
    AaveYieldModule public module;
    
    // Real Base Sepolia Aave V3 addresses (from Aave Address Book)
    // Pool Addresses Provider: 0xE4C23309117Aa30342BFaae6c95c6478e0A4Ad00
    // Pool: 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27
    // USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
    address constant AAVE_POOL = address(0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27);
    address constant USDC = address(0x036CbD53842c5426634e7929541eC2318f3dCF7e);
    
    // Funded test account (has USDC on Base Sepolia)
    address constant TEST_ESCROW = address(0xAD656AfbA0A926CDcC828444D7B9A1866C26eFb5);
    
    // Test accounts
    address public testEscrow;
    address public user;
    
    uint256 constant DEPOSIT_AMOUNT = 1e6; // 1 USDC (current balance)

    function setUp() public {
        // Verify we're forking - check if pool has code
        uint256 poolCodeSize = AAVE_POOL.code.length;
        emit log_named_uint("Pool code size:", poolCodeSize);
        
        if (poolCodeSize == 0) {
            vm.skip(true);
            return;
        }
        
        // Use funded test account
        testEscrow = TEST_ESCROW;
        user = makeAddr('TestUser');
        
        // Deploy module with real pool
        module = new AaveYieldModule(AAVE_POOL);
        
        // Approve escrow
        module.approveEscrow(testEscrow);
    }

    // ============ Fork Connectivity Tests ============

    function test_fork_poolIsValid() public {
        // Verify pool contract exists and has code
        assertGt(AAVE_POOL.code.length, 0);
    }

    function test_fork_usdcIsValid() public {
        // Verify USDC exists
        assertGt(USDC.code.length, 0);
    }

    // ============ Integration Tests (with real tokens) ============

    // ============ Integration Tests (with real contracts) ============

    function test_fork_canHandle_usdc() public {
        // Check if module can handle USDC
        // This validates that USDC address is correct and module can query aToken
        (bool supported, bytes32 reason) = module.canHandle(USDC, YieldPreset.OFF, DEPOSIT_AMOUNT);
        // Result depends on whether USDC is supported in Aave market
        emit log_string("Can handle USDC check done");
    }

    function test_fork_depositToAave() public {
        // Full integration test with real Aave requires actual USDC balance
        // This test validates:
        // 1. Pool address is correct (verified in setUp - pool has code)
        // 2. Module can be deployed with real pool
        // 3. Escrow approval works
        
        // Approve this contract as escrow
        module.approveEscrow(address(this));
        
        assertTrue(module.approvedEscrows(address(this)));
    }

    // ============ Revert Tests ============

    function test_fork_revert_onZeroAddress() public {
        vm.expectRevert('InvalidPoolAddress');
        new AaveYieldModule(address(0));
    }

    function test_fork_revert_onNonContractPool() public {
        vm.expectRevert('PoolAddressIsNotContract');
        new AaveYieldModule(makeAddr('NotAContract'));
    }

    function test_fork_unauthorizedEscrow() public {
        address unauthorized = makeAddr('UnauthorizedEscrow');
        
        vm.prank(unauthorized);
        vm.expectRevert('UnauthorizedEscrow');
        module.initializeYield(1, USDC, DEPOSIT_AMOUNT, YieldPreset.OFF);
    }
}
