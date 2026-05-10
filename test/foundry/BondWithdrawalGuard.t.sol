// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../contracts/modules/decentralized-resolution-module/ResolverStakingModuleV1.sol";
import "../../contracts/modules/decentralized-resolution-module/ResolverSlashingModuleV1.sol";
import "../../contracts/modules/decentralized-resolution-module/InsurancePoolVault.sol";
import "../../contracts/mocks/ERC20Mock.sol";

contract BondWithdrawalGuardTest is Test {
    ResolverStakingModuleV1 public staking;
    ResolverSlashingModuleV1 public slashing;
    InsurancePoolVault public insurance;
    ERC20Mock public stableToken;
    ERC20Mock public sewToken;

    address public admin = address(0x0000000000000000000000000000000000000001);
    address public resolver = address(0x1234567890123456789012345678901234567890);

    function setUp() public {
        vm.startPrank(admin);
        stableToken = new ERC20Mock("USDC", "USDC", admin, 1000000 ether);
        sewToken = new ERC20Mock("SEW", "SEW", admin, 1000000 ether);
        insurance = new InsurancePoolVault(address(stableToken), admin);
        
        staking = new ResolverStakingModuleV1(admin, address(stableToken), address(sewToken));
        slashing = new ResolverSlashingModuleV1(admin, address(staking), address(insurance), address(stableToken));
        
        // Grant roles for setup
        staking.grantRole(staking.ROLE_TIMELOCK(), admin);
        slashing.grantRole(slashing.ROLE_TIMELOCK(), admin);
        slashing.grantRole(slashing.ROLE_RESOLUTION_MODULE(), admin);
        
        staking.setSlashingModule(address(slashing));
        
        // Enable fraud slashing for testing
        slashing.setSlashPercentage(ISlashingModule.SlashReason.FRAUD, 5000); // 50%
        
        vm.stopPrank();

        // Setup resolver stake
        vm.startPrank(admin);
        stableToken.transfer(resolver, 1000 ether);
        sewToken.transfer(resolver, 1000 ether); // Fix: removed typo from original prompt.
        vm.stopPrank();

        vm.startPrank(resolver);
        stableToken.approve(address(staking), 1000 ether);
        sewToken.approve(address(staking), 1000 ether);
        // Note: depositStakeWithMix doesn't exist, using depositStake directly
        staking.stakeWithMix(500 ether, 500 ether);
        vm.stopPrank();
    }

    function test_CannotWithdrawDuringPendingSlash() public {
        // Propose a fraud slash
        vm.startPrank(admin);
        slashing.slashForFraud(1, address(0), resolver, "");
        vm.stopPrank();

        // Attempt withdrawal - should revert
        vm.startPrank(resolver);
        vm.expectRevert(abi.encodeWithSignature("ResolverHasPendingSlash(address)", resolver));
        staking.requestUnstakeWithMix(10 ether, 0);
        vm.stopPrank();
    }

    function test_CannotCompleteUnstakeDuringPendingSlash() public {
        // 1. Request unstake
        vm.startPrank(resolver);
        staking.requestUnstakeWithMix(10 ether, 0);
        vm.stopPrank();

        // 2. Warp past delay (assume 7 days based on common protocol constants)
        vm.warp(block.timestamp + 8 days);

        // 3. Propose a slash
        vm.startPrank(admin);
        slashing.slashForFraud(1, address(0), resolver, "");
        vm.stopPrank();

        // 4. Attempt to complete unstake - should revert
        vm.startPrank(resolver);
        vm.expectRevert(abi.encodeWithSignature("ResolverHasPendingSlash(address)", resolver));
        staking.completeUnstake();
        vm.stopPrank();
    }
}
