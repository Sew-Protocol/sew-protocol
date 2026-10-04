// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/staking/ResolverStakingModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/interfaces/IStakingModule.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract MockStable is ERC20 {
    constructor() ERC20('Mock USDC', 'USDC') { _mint(msg.sender, 1000000e6); }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockSEW is ERC20 {
    constructor() ERC20('Mock SEW', 'SEW') { _mint(msg.sender, 1000000e18); }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Focused unit tests for ResolverStakingModule core lifecycle + views
///         (complements the existing invariant suite).
contract ResolverStakingModuleUnitTest is Test {
    ResolverStakingModule public staking;
    MockStable public stable;
    MockSEW public sew;

    address admin = address(0xAD01);
    address resolver = address(0x10);
    address senior = address(0x11);
    address outsider = address(0x99);

    function setUp() public {
        stable = new MockStable();
        sew = new MockSEW();
        staking = new ResolverStakingModule(admin, address(stable), address(sew));
        // grant admin the ROLE_TIMELOCK needed for pause / setResolverTier
        bytes32 timelockRole = staking.ROLE_TIMELOCK();
        vm.prank(admin);
        staking.grantRole(timelockRole, admin);
    }

    function _stakeStable(address who, uint256 usd) internal {
        uint256 amt = usd * 1e6; // 6-decimal stable
        stable.mint(who, amt);
        vm.startPrank(who);
        stable.approve(address(staking), amt);
        staking.stake(amt);
        vm.stopPrank();
    }

    function test_stakeAndView() public {
        _stakeStable(resolver, 1000);
        (uint256 s, uint256 w, uint256 eff, uint256 stPct, uint256 sewPct) = staking.getBondComposition(resolver);
        assertEq(s, 1000e6);
        assertEq(w, 0);
        assertGt(eff, 0);
        assertGt(stPct, 0);

        ResolverStakingModule.StakeInfo memory info = staking.getStakeInfo(resolver);
        assertEq(info.totalStake, 1000e18); // effectiveBondUSD normalized to 18-dec
        assertEq(uint(info.status), uint(IStakingModule.StakeStatus.ACTIVE));
        assertEq(staking.getAvailableStake(resolver), info.availableStake);
        assertEq(staking.getEffectiveStake(resolver), info.availableStake);
    }

    function test_stake_belowMinimumReverts() public {
        stable.mint(resolver, 10e6);
        vm.startPrank(resolver);
        stable.approve(address(staking), 10e6);
        vm.expectRevert();
        staking.stake(10e6); // 10 USD < 250 USD minimum
        vm.stopPrank();
    }

    function test_stake_zeroReverts() public {
        vm.prank(resolver);
        vm.expectRevert(ResolverStakingModule.ZeroStakeAmount.selector);
        staking.stake(0);
    }

    function test_stake_pausedReverts() public {
        vm.prank(admin);
        staking.pause('test');
        assertTrue(staking.isPaused());
        vm.prank(resolver);
        vm.expectRevert(ResolverStakingModule.ContractPaused.selector);
        staking.stake(100e6);
    }

    function test_requestAndCancelUnstake() public {
        _stakeStable(resolver, 1000);
        vm.prank(resolver);
        staking.requestUnstake(200e6); // request unstake of 200 USDC

        vm.prank(resolver);
        staking.cancelUnstake();
        // after cancel, bond unchanged
        (uint256 s, , , , ) = staking.getBondComposition(resolver);
        assertEq(s, 1000e6);
    }

    function test_requestUnstake_noStakeReverts() public {
        vm.prank(resolver);
        vm.expectRevert();
        staking.requestUnstake(100e6);
    }

    function test_completeUnstake_afterDelay() public {
        _stakeStable(resolver, 1000);
        vm.prank(resolver);
        staking.requestUnstake(200e6);

        vm.warp(block.timestamp + staking.RESOLVER_UNBOND_DELAY() + 1);
        vm.prank(resolver);
        staking.completeUnstake();

        (uint256 s, , , , ) = staking.getBondComposition(resolver);
        assertEq(s, 800e6); // 1000 - 200
        assertEq(stable.balanceOf(resolver), 200e6);
    }

    function test_completeUnstake_beforeDelayReverts() public {
        _stakeStable(resolver, 1000);
        vm.prank(resolver);
        staking.requestUnstake(200e6);

        // No warp -> still in delay
        vm.prank(resolver);
        vm.expectRevert();
        staking.completeUnstake();
    }

    function test_getters() public {
        _stakeStable(resolver, 1000);
        assertEq(staking.getMinimumStake(0), 250e18);
        assertEq(staking.getMinimumStake(1), 25000e18);
        assertEq(staking.getStakeToken(), address(stable));
        assertGt(staking.getMaxEscrowPerCase(resolver), 0);
        assertTrue(staking.isStakeSufficient(resolver, 0));
        assertFalse(staking.isPaused());
    }

    function test_delegateStake() public {
        // Set tiers
        vm.startPrank(admin);
        staking.setResolverTier(resolver, 0);
        staking.setResolverTier(senior, 1);
        vm.stopPrank();

        _stakeStable(resolver, 1000); // junior
        _stakeStable(senior, 200000); // senior, large coverage

        vm.prank(resolver);
        staking.delegateStake(senior, 0);

        IStakingModule.DelegationInfo memory info = staking.getActiveDelegation(resolver);
        assertEq(info.delegatee, senior);
        assertTrue(info.active);
        assertGt(info.amount, 0);
    }
}
