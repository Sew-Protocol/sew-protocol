// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/types/YieldPresets.sol';

/**
 * @title AaveYieldModuleMainnetForkTest
 * @notice Simple fork test to verify Aave connectivity on Base Mainnet
 * 
 * Run: forge test --match-contract AaveYieldModuleMainnetForkTest -vvv --fork-url https://mainnet.base.org
 */
contract AaveYieldModuleMainnetForkTest is Test {
    AaveYieldModule public module;
    
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    
    function setUp() public {
        if (AAVE_POOL.code.length == 0) {
            vm.skip(true);
        }
        
        module = new AaveYieldModule(AAVE_POOL);
    }
    
    function test_fork_poolExists() public view {
        assertGt(AAVE_POOL.code.length, 0);
    }
    
    function test_fork_usdcExists() public view {
        assertGt(USDC.code.length, 0);
    }
    
    function test_fork_deployModule() public view {
        assertEq(address(module.aavePool()), AAVE_POOL);
    }
    
    function test_fork_tokenToAToken() public view {
        address aToken = module.tokenToAToken(USDC);
        assertEq(aToken, address(0), "USDC should not be pre-configured in module");
    }
    
    function test_fork_canHandle() public view {
        (bool supported, bytes32 reason) = module.canHandle(USDC, YieldPreset.TO_SENDER, 100e6);
        assertTrue(supported, "USDC should be supported on Base mainnet");
    }
}
