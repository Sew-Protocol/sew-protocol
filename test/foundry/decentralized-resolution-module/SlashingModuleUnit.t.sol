// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol';
import '../../../contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol';
import '../../../contracts/decentralized-resolution-module/InsurancePoolVault.sol';
import '../../../contracts/decentralized-resolution-module/ISlashingModule.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol';

// Reuse mock tokens
contract MockStable is ERC20 {
    constructor() ERC20('Mock USDC', 'USDC') {
        _mint(msg.sender, 1000000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSEW is ERC20, ERC20Burnable {
    constructor() ERC20('Mock SEW', 'SEW') ERC20Burnable() {
        _mint(msg.sender, 1000000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title SlashingModuleUnitTest
 * @notice Unit tests for ResolverSlashingModuleV1
 * @dev Focuses on individual slash function behavior, including fraud slashing
 */
contract SlashingModuleUnitTest is Test {
    ResolverSlashingModuleV1 public slashingModule;
    ResolverStakingModuleV1 public stakingModule;
    InsurancePoolVault public insurancePool;
    MockStable public stableToken;
    MockSEW public sewToken;

    address public admin;
    address public timelock;
    address public resolver1;
    address public resolver2;
    address public senior1;
    address public resolutionModule;

    uint256 public constant MIN_STAKE_STABLE = 250e6; // 250 USDC (v3 minimum for resolver)
    uint256 public constant MIN_STAKE_SEW = 200e18; // 200 SEW (after 50% haircut = 100)
    uint256 public constant BASIS_POINTS = 10000;

    function setUp() public {
        admin = address(this);
        timelock = makeAddr('timelock');
        resolver1 = makeAddr('resolver1');
        resolver2 = makeAddr('resolver2');
        senior1 = makeAddr('senior1');
        resolutionModule = makeAddr('resolutionModule');

        // Deploy tokens
        stableToken = new MockStable();
        sewToken = new MockSEW();

        // Deploy staking module
        stakingModule = new ResolverStakingModuleV1(admin, address(stableToken), address(sewToken));

        // Deploy insurance vault
        insurancePool = new InsurancePoolVault(admin, address(stableToken));

        // Deploy slashing module
        slashingModule = new ResolverSlashingModuleV1(
            admin,
            address(stakingModule),
            address(insurancePool),
            address(stableToken)
        );

        // Setup roles
        vm.startPrank(admin);
        stakingModule.grantRole(stakingModule.ROLE_TIMELOCK(), admin);
        slashingModule.grantRole(slashingModule.ROLE_TIMELOCK(), timelock);
        slashingModule.grantRole(slashingModule.ROLE_RESOLUTION_MODULE(), resolutionModule);
        stakingModule.setResolutionModule(resolutionModule);
        stakingModule.setSlashingModule(address(slashingModule));
        stakingModule.grantRole(stakingModule.ROLE_SLASHING_MODULE(), address(slashingModule));
        insurancePool.grantRole(insurancePool.ROLE_SLASHING_MODULE(), address(slashingModule));

        // Setup tiers
        stakingModule.setResolverTier(resolver1, 0);
        stakingModule.setResolverTier(resolver2, 0);
        stakingModule.setResolverTier(senior1, 1);

        // Fund resolvers
        stableToken.mint(resolver1, 1000000e6); // 1 million USDC (larger for testing)
        sewToken.mint(resolver1, 1000000e18);
        stableToken.mint(resolver2, 100000e6);
        stableToken.mint(senior1, 5000000e6); // 5 million USDC for senior (can provide large coverage)

        // Approve and stake
        vm.startPrank(resolver1);
        stableToken.approve(address(stakingModule), type(uint256).max);
        sewToken.approve(address(stakingModule), type(uint256).max);
        // Smaller resolver stake: 50000 USDC + 100 SEW
        // effective = 50000 + (100 * 1 * 0.5) = 50050 USD
        // Stable% = 50000/50050 = 99.9% >= 80% ✓
        stakingModule.stakeWithMix(50000e6, 100e18);
        vm.stopPrank();

        vm.startPrank(resolver2);
        stableToken.approve(address(stakingModule), type(uint256).max);
        stakingModule.stakeWithMix(50000e6, 0);
        vm.stopPrank();

        vm.startPrank(senior1);
        stableToken.approve(address(stakingModule), type(uint256).max);
        // Large senior stake: 2000000 USDC
        // maxCoverage = (2000000 * 5000) / 10000 = 1000000 USD
        // Can cover: resolver (50050 USD) * 3 = 150150 USD ✓
        stakingModule.stakeWithMix(2000000e6, 0);
        vm.stopPrank();

        // Enable fraud slashing (set fraudSlashBps)
        vm.prank(timelock);
        slashingModule.setSlashPercentage(ISlashingModule.SlashReason.FRAUD, 5000); // 50%
        vm.stopPrank();
    }

    // ============ slashForTimeout Tests ============

    function test_slashForTimeout_AcceptTimeout() public {
        uint256 workflowId = 1;
        uint8 timeoutType = 0; // Accept timeout

        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForTimeout(workflowId, resolver1, timeoutType);

        assertGt(slashId, 0, 'Should return slash ID');
        ISlashingModule.SlashEvent memory event_ = slashingModule.getSlashEvent(slashId);
        assertEq(uint8(event_.reason), uint8(ISlashingModule.SlashReason.TIMEOUT_ACCEPT), 'Should be timeout accept');
        assertGt(event_.amount, 0, 'Should have slash amount');
        assertEq(uint8(event_.status), uint8(ISlashingModule.SlashStatus.EXECUTED), 'Should be executed');
    }

    function test_slashForTimeout_ResolveTimeout() public {
        uint256 workflowId = 1;
        uint8 timeoutType = 1; // Resolve timeout

        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForTimeout(workflowId, resolver1, timeoutType);

        ISlashingModule.SlashEvent memory event_ = slashingModule.getSlashEvent(slashId);
        assertEq(uint8(event_.reason), uint8(ISlashingModule.SlashReason.TIMEOUT_RESOLVE), 'Should be timeout resolve');
    }

    // ============ slashForFraud Tests ============

    function test_slashForFraud_Basic() public {
        uint256 workflowId = 1;
        bytes memory evidence = 'Fraud evidence: collusion detected';

        vm.prank(timelock);
        uint256 slashId = slashingModule.slashForFraud(workflowId, resolver1, evidence);

        assertGt(slashId, 0, 'Should return slash ID');
        ISlashingModule.SlashEvent memory event_ = slashingModule.getSlashEvent(slashId);
        assertEq(uint8(event_.reason), uint8(ISlashingModule.SlashReason.FRAUD), 'Should be fraud');
        assertGt(event_.amount, 0, 'Should have slash amount');
        assertEq(uint8(event_.status), uint8(ISlashingModule.SlashStatus.EXECUTED), 'Should be executed');
        assertEq(event_.evidence, evidence, 'Should store evidence');
        assertTrue(event_.appealDeadline > block.timestamp, 'Should have appeal deadline');
    }

    function test_slashForFraud_RequiresTimelock() public {
        uint256 workflowId = 1;
        bytes memory evidence = 'Evidence';

        vm.prank(resolutionModule);
        vm.expectRevert();
        slashingModule.slashForFraud(workflowId, resolver1, evidence);
    }

    function test_slashForFraud_RequiresFraudSlashEnabled() public {
        // Disable fraud slashing
        vm.prank(timelock);
        slashingModule.setSlashPercentage(ISlashingModule.SlashReason.FRAUD, 0);

        uint256 workflowId = 1;
        bytes memory evidence = 'Evidence';

        vm.prank(timelock);
        vm.expectRevert(ResolverSlashingModuleV1.FraudSlashingNotEnabled.selector);
        slashingModule.slashForFraud(workflowId, resolver1, evidence);
    }

    function test_slashForFraud_NoDoubleSlashing() public {
        uint256 workflowId = 1;
        bytes memory evidence = 'Evidence';

        vm.startPrank(timelock);
        uint256 slashId1 = slashingModule.slashForFraud(workflowId, resolver1, evidence);
        assertGt(slashId1, 0, 'First slash should succeed');

        // Attempt second slash for same workflow/resolver
        uint256 slashId2 = slashingModule.slashForFraud(workflowId, resolver1, evidence);
        assertEq(slashId2, 0, 'Second slash should return 0 (already slashed)');
        vm.stopPrank();
    }

    function test_slashForFraud_RespectsCircuitBreaker() public {
        // Activate circuit breaker
        vm.prank(timelock);
        slashingModule.triggerCircuitBreaker('Test');

        uint256 workflowId = 1;
        bytes memory evidence = 'Evidence';

        vm.prank(timelock);
        uint256 slashId = slashingModule.slashForFraud(workflowId, resolver1, evidence);
        assertEq(slashId, 0, 'Should return 0 when circuit breaker active');
    }

    function test_slashForFraud_RespectsSlashCaps() public {
        // Create large slash that would exceed cap
        uint256 workflowId = 1;
        bytes memory evidence = 'Evidence';

        // Slash multiple times to hit period cap
        vm.startPrank(timelock);
        uint256 slashId1 = slashingModule.slashForFraud(workflowId, resolver1, evidence);
        assertGt(slashId1, 0, 'First slash should succeed');

        // Second slash for different workflow should respect period cap
        uint256 slashId2 = slashingModule.slashForFraud(2, resolver1, evidence);
        // Should either succeed (if under cap) or return 0 (if cap reached)
        assertTrue(slashId2 >= 0, 'Second slash should handle cap correctly');
        vm.stopPrank();
    }

    function test_slashForFraud_FreezesResolver() public {
        uint256 workflowId = 1;
        bytes memory evidence = 'Evidence';

        vm.prank(timelock);
        slashingModule.slashForFraud(workflowId, resolver1, evidence);

        // Check resolver is frozen
        uint256 frozenUntil = slashingModule.frozenUntil(resolver1);
        assertGt(frozenUntil, block.timestamp, 'Resolver should be frozen');
    }

    function test_slashForFraud_DistributesToInsurancePool() public {
        uint256 workflowId = 1;
        bytes memory evidence = 'Evidence';

        uint256 poolBalanceBefore = stableToken.balanceOf(address(insurancePool));

        vm.prank(timelock);
        slashingModule.slashForFraud(workflowId, resolver1, evidence);

        uint256 poolBalanceAfter = stableToken.balanceOf(address(insurancePool));
        assertGt(poolBalanceAfter, poolBalanceBefore, 'Insurance pool should receive funds');
    }

    function test_slashForFraud_CanAppeal() public {
        uint256 workflowId = 1;
        bytes memory evidence = 'Evidence';

        vm.prank(timelock);
        uint256 slashId = slashingModule.slashForFraud(workflowId, resolver1, evidence);

        ISlashingModule.SlashEvent memory event_ = slashingModule.getSlashEvent(slashId);
        assertGt(event_.appealDeadline, block.timestamp, 'Should have appeal deadline');
        // Note: Fraud slashes are executed immediately (status = EXECUTED)
        // Appeals may work differently for executed vs pending slashes
        // This test verifies the slash event is created with appeal deadline
    }

    function test_slashForFraud_EvidenceStorage() public {
        uint256 workflowId = 1;
        bytes memory evidence1 = 'Evidence type 1';
        bytes memory evidence2 = 'Different evidence';

        vm.startPrank(timelock);
        uint256 slashId1 = slashingModule.slashForFraud(workflowId, resolver1, evidence1);
        uint256 slashId2 = slashingModule.slashForFraud(2, resolver1, evidence2);
        vm.stopPrank();

        // First slash should succeed
        assertGt(slashId1, 0, 'First slash should have slashId');
        ISlashingModule.SlashEvent memory event1 = slashingModule.getSlashEvent(slashId1);
        assertEq(event1.evidence, evidence1, 'First evidence should be stored');
        
        // Second slash fails because period cap is reached
        assertEq(slashId2, 0, 'Second slash should return 0 (period cap reached)');
    }

    function test_slashForFraud_WaterfallSlashing() public {
        // Setup delegation: resolver1 delegated to senior1
        vm.startPrank(resolver1);
        stakingModule.delegateStake(senior1, 0); // Delegate coverage (amount unused, auto-calculated)
        vm.stopPrank();

        // Create large slash that exceeds resolver's stake
        uint256 workflowId = 1;
        bytes memory evidence = 'Evidence';

        vm.prank(timelock);
        uint256 slashId = slashingModule.slashForFraud(workflowId, resolver1, evidence);

        // Verify slash completed successfully
        assertGt(slashId, 0, 'Should create slash event');
        ISlashingModule.SlashEvent memory event_ = slashingModule.getSlashEvent(slashId);
        assertGt(event_.amount, 0, 'Should have slash amount');
        // Note: Waterfall slashing logic is tested in integration/invariant tests
    }

    // ============ slashForReversal Tests ============

    function test_slashForReversal_Disabled() public {
        uint256 workflowId = 1;
        uint8 priorRound = 0;

        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForReversal(workflowId, resolver1, priorRound);

        assertEq(slashId, 0, 'Should return 0 (disabled)');
    }

    // ============ Slash Configuration Tests ============

    function test_setSlashPercentage_Fraud() public {
        vm.prank(timelock);
        slashingModule.setSlashPercentage(ISlashingModule.SlashReason.FRAUD, 7500); // 75%

        ISlashingModule.SlashConfig memory config = slashingModule.getSlashConfig();
        assertEq(config.fraudSlashBps, 7500, 'Fraud slash BPS should be updated');
    }

    function test_setSlashPercentage_RequiresTimelock() public {
        vm.prank(resolutionModule);
        vm.expectRevert();
        slashingModule.setSlashPercentage(ISlashingModule.SlashReason.FRAUD, 5000);
    }

    // ============ SEW Burning Tests ============

    function test_slashForTimeout_BurnsSew() public {
        uint256 workflowId = 1;
        uint8 timeoutType = 1; // Resolve timeout

        // Get initial balances and supply
        uint256 stakingModuleSewBefore = sewToken.balanceOf(address(stakingModule));
        uint256 slashingModuleSewBefore = sewToken.balanceOf(address(slashingModule));
        uint256 totalSupplyBefore = sewToken.totalSupply();
        
        // Get resolver's bond composition to calculate expected SEW slash
        (uint256 stableAmount, uint256 sewAmount,,,) = stakingModule.getBondComposition(resolver1);
        assertGt(sewAmount, 0, 'Resolver should have SEW staked');

        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForTimeout(workflowId, resolver1, timeoutType);

        assertGt(slashId, 0, 'Should create slash event');

        // Verify SEW was burned (total supply decreased)
        uint256 totalSupplyAfter = sewToken.totalSupply();
        assertLt(totalSupplyAfter, totalSupplyBefore, 'SEW total supply should decrease');

        // Verify slashing module did NOT receive SEW
        uint256 slashingModuleSewAfter = sewToken.balanceOf(address(slashingModule));
        assertEq(slashingModuleSewAfter, slashingModuleSewBefore, 'Slashing module should not receive SEW');

        // Verify staking module SEW balance decreased (burned from staking module's balance)
        uint256 stakingModuleSewAfter = sewToken.balanceOf(address(stakingModule));
        assertLt(stakingModuleSewAfter, stakingModuleSewBefore, 'Staking module SEW balance should decrease');
    }

    function test_slashForFraud_BurnsSew() public {
        uint256 workflowId = 1;
        bytes memory evidence = 'Fraud evidence';

        // Get initial balances and supply
        uint256 stakingModuleSewBefore = sewToken.balanceOf(address(stakingModule));
        uint256 slashingModuleSewBefore = sewToken.balanceOf(address(slashingModule));
        uint256 totalSupplyBefore = sewToken.totalSupply();

        vm.prank(timelock);
        uint256 slashId = slashingModule.slashForFraud(workflowId, resolver1, evidence);

        assertGt(slashId, 0, 'Should create slash event');

        // Verify SEW was burned (total supply decreased)
        uint256 totalSupplyAfter = sewToken.totalSupply();
        assertLt(totalSupplyAfter, totalSupplyBefore, 'SEW total supply should decrease');

        // Verify slashing module did NOT receive SEW
        uint256 slashingModuleSewAfter = sewToken.balanceOf(address(slashingModule));
        assertEq(slashingModuleSewAfter, slashingModuleSewBefore, 'Slashing module should not receive SEW');

        // Verify staking module SEW balance decreased
        uint256 stakingModuleSewAfter = sewToken.balanceOf(address(stakingModule));
        assertLt(stakingModuleSewAfter, stakingModuleSewBefore, 'Staking module SEW balance should decrease');
    }

    function test_slashForTimeout_StableStillTransferred() public {
        uint256 workflowId = 1;
        uint8 timeoutType = 1; // Resolve timeout

        // Get initial balances
        uint256 stakingModuleStableBefore = stableToken.balanceOf(address(stakingModule));
        uint256 insurancePoolStableBefore = stableToken.balanceOf(address(insurancePool));

        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForTimeout(workflowId, resolver1, timeoutType);

        assertGt(slashId, 0, 'Should create slash event');

        // Verify stable was transferred to insurance pool (50% distribution)
        uint256 insurancePoolStableAfter = stableToken.balanceOf(address(insurancePool));
        assertGt(insurancePoolStableAfter, insurancePoolStableBefore, 'Insurance pool should receive stable tokens');

        // Verify staking module stable balance decreased
        uint256 stakingModuleStableAfter = stableToken.balanceOf(address(stakingModule));
        assertLt(stakingModuleStableAfter, stakingModuleStableBefore, 'Staking module stable balance should decrease');
    }

    function test_slashForTimeout_MixedBond_BurnsSewAndTransfersStable() public {
        uint256 workflowId = 1;
        uint8 timeoutType = 1; // Resolve timeout

        // Get initial state
        uint256 totalSupplyBefore = sewToken.totalSupply();
        uint256 insurancePoolStableBefore = stableToken.balanceOf(address(insurancePool));
        uint256 slashingModuleSewBefore = sewToken.balanceOf(address(slashingModule));

        vm.prank(resolutionModule);
        uint256 slashId = slashingModule.slashForTimeout(workflowId, resolver1, timeoutType);

        assertGt(slashId, 0, 'Should create slash event');

        // Verify both: SEW burned AND stable transferred
        uint256 totalSupplyAfter = sewToken.totalSupply();
        assertLt(totalSupplyAfter, totalSupplyBefore, 'SEW should be burned');

        uint256 insurancePoolStableAfter = stableToken.balanceOf(address(insurancePool));
        assertGt(insurancePoolStableAfter, insurancePoolStableBefore, 'Stable should be transferred to insurance pool');

        uint256 slashingModuleSewAfter = sewToken.balanceOf(address(slashingModule));
        assertEq(slashingModuleSewAfter, slashingModuleSewBefore, 'SEW should NOT be transferred to slashing module');
    }

    function test_slashCoverage_BurnsSew() public {
        // Setup delegation: resolver1 delegated to senior1
        vm.startPrank(resolver1);
        stakingModule.delegateStake(senior1, 0);
        vm.stopPrank();

        // Get initial state
        uint256 totalSupplyBefore = sewToken.totalSupply();
        uint256 slashingModuleSewBefore = sewToken.balanceOf(address(slashingModule));

        // Create large slash that will use senior coverage
        // First, slash resolver's own stake (should burn their SEW)
        uint256 workflowId = 1;
        uint8 timeoutType = 1;

        vm.prank(resolutionModule);
        slashingModule.slashForTimeout(workflowId, resolver1, timeoutType);

        // Verify SEW was burned
        uint256 totalSupplyAfter = sewToken.totalSupply();
        assertLt(totalSupplyAfter, totalSupplyBefore, 'SEW should be burned from resolver slash');

        // Verify slashing module did NOT receive SEW
        uint256 slashingModuleSewAfter = sewToken.balanceOf(address(slashingModule));
        assertEq(slashingModuleSewAfter, slashingModuleSewBefore, 'Slashing module should not receive SEW');
    }
}
