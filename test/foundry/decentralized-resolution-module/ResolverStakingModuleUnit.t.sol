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

contract MockPendingSlashSource {
    uint256 public totalPendingSlashCount;
    function setPending(uint256 count) external { totalPendingSlashCount = count; }
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

    function test_vindicationReceivableDoesNotMintOrInflateStake() public {
        _stakeStable(resolver, 1000);
        (uint256 stableBefore,, uint256 effectiveBefore,,) = staking.getBondComposition(resolver);
        uint256 receivableUSD = 100e18;

        bytes32 slashRole = staking.ROLE_SLASHING_MODULE();
        vm.prank(admin);
        staking.grantRole(slashRole, admin);
        vm.prank(admin);
        staking.recordVindicationReceivable(resolver, receivableUSD);

        (uint256 stableAfter,, uint256 effectiveAfter,,) = staking.getBondComposition(resolver);
        assertEq(stableAfter, stableBefore, 'stable token custody accounting unchanged');
        assertEq(effectiveAfter, effectiveBefore, 'unfunded receivable is not stake');
        assertEq(staking.vindicationReceivableUSD(resolver), receivableUSD, 'receivable uses USD 18-decimal units');
        assertEq(staking.getAvailableStake(resolver), effectiveBefore, 'capacity remains custody backed');
        assertEq(stable.balanceOf(address(staking)), stableBefore, 'staking custody unchanged');
    }

    function test_activeAssignmentLockPreventsUnstakeUntilFinalization() public {
        _stakeStable(resolver, 1000);
        bytes32 resolutionRole = staking.ROLE_RESOLUTION_MODULE();
        vm.prank(admin);
        staking.grantRole(resolutionRole, admin);

        uint256 requiredStake = 250e18;
        vm.prank(admin);
        staking.onResolverAssigned(7, address(0xE5C0), resolver, requiredStake);
        assertEq(staking.totalLockedStake(resolver), requiredStake);
        assertEq(staking.lockedStakes(address(0xE5C0), 7, resolver), requiredStake);

        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(ResolverStakingModule.StakeLockedInDisputes.selector, resolver, requiredStake)
        );
        staking.requestUnstake(1000e6);

        vm.prank(admin);
        staking.onResolutionFinalized(7, address(0xE5C0), resolver, true);
        assertEq(staking.totalLockedStake(resolver), 0);
        assertEq(staking.lockedStakes(address(0xE5C0), 7, resolver), 0);
    }

    function test_zeroAmountAssignmentIsSingleUseAndBlocksModuleRotationUntilReleased() public {
        vm.prank(admin);
        staking.setMinimumStake(0, 0);
        vm.prank(admin);
        staking.setResolutionModule(address(this));

        address workflowEscrow = address(0xE5C0);
        staking.onResolverAssigned(8, workflowEscrow, resolver, 0);
        assertTrue(staking.activeStakeAssignments(workflowEscrow, 8, resolver));
        assertEq(staking.activeResolutionAssignments(), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ResolverStakingModule.StakeAssignmentAlreadyActive.selector,
                workflowEscrow, 8, resolver
            )
        );
        staking.onResolverAssigned(8, workflowEscrow, resolver, 0);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ResolverStakingModule.ActiveResolutionAssignments.selector, 1)
        );
        staking.setResolutionModule(address(0xA11CE));

        staking.onResolutionFinalized(8, workflowEscrow, resolver, true);
        assertFalse(staking.activeStakeAssignments(workflowEscrow, 8, resolver));
        assertEq(staking.activeResolutionAssignments(), 0);

        vm.prank(admin);
        staking.setResolutionModule(address(0xA11CE));
        assertFalse(staking.hasRole(staking.ROLE_RESOLUTION_MODULE(), address(this)));
        assertTrue(staking.hasRole(staking.ROLE_RESOLUTION_MODULE(), address(0xA11CE)));
    }

    function test_slashConsumesOnlyFreeAndTargetAssignmentStake() public {
        _stakeStable(resolver, 1000);
        bytes32 resolutionRole = staking.ROLE_RESOLUTION_MODULE();
        bytes32 slashRole = staking.ROLE_SLASHING_MODULE();
        vm.startPrank(admin);
        staking.grantRole(resolutionRole, admin);
        staking.grantRole(slashRole, admin);
        staking.setSlashingModule(address(this));
        staking.onResolverAssigned(1, address(0xE501), resolver, 250e18);
        staking.onResolverAssigned(2, address(0xE502), resolver, 250e18);
        vm.stopPrank();

        vm.prank(admin);
        staking.slashForAssignment(resolver, 900e18, address(0xE501), 1);

        assertEq(staking.lockedStakes(address(0xE501), 1, resolver), 0, 'target assignment collateral can be slashed');
        assertEq(staking.lockedStakes(address(0xE502), 2, resolver), 250e18, 'other assignment remains backed');
        assertEq(staking.totalLockedStake(resolver), 250e18, 'aggregate lock retains other assignment');
        ResolverStakingModule.StakeInfo memory info = staking.getStakeInfo(resolver);
        assertGe(info.totalStake, info.lockedStake, 'slash cannot create an under-backed lock');
    }

    function test_unscopedSlashCannotConsumeAssignedCollateral() public {
        _stakeStable(resolver, 1000);
        bytes32 resolutionRole = staking.ROLE_RESOLUTION_MODULE();
        bytes32 slashRole = staking.ROLE_SLASHING_MODULE();
        vm.startPrank(admin);
        staking.grantRole(resolutionRole, admin);
        staking.grantRole(slashRole, admin);
        staking.setSlashingModule(address(this));
        staking.onResolverAssigned(3, address(0xE503), resolver, 250e18);
        vm.stopPrank();

        vm.prank(admin);
        staking.slash(resolver, 900e18);

        assertEq(staking.lockedStakes(address(0xE503), 3, resolver), 250e18);
        ResolverStakingModule.StakeInfo memory info = staking.getStakeInfo(resolver);
        assertGe(info.totalStake, info.lockedStake);
    }

    function test_slashingModuleRotationRequiresNoPendingSlashAndRevokesOldRole() public {
        MockPendingSlashSource oldSlasher = new MockPendingSlashSource();
        address nextSlasher = address(0x51A5);

        vm.prank(admin);
        staking.setSlashingModule(address(oldSlasher));
        assertTrue(staking.hasRole(staking.ROLE_SLASHING_MODULE(), address(oldSlasher)));

        oldSlasher.setPending(1);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ResolverStakingModule.PendingSlashingOperations.selector, 1)
        );
        staking.setSlashingModule(nextSlasher);

        oldSlasher.setPending(0);
        vm.prank(admin);
        staking.setSlashingModule(nextSlasher);
        assertFalse(staking.hasRole(staking.ROLE_SLASHING_MODULE(), address(oldSlasher)));
        assertTrue(staking.hasRole(staking.ROLE_SLASHING_MODULE(), nextSlasher));
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
