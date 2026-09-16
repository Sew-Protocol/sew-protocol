// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/EscrowCreationPolicy.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/interfaces/IYieldModule.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';

/// @notice Minimal yield module that accepts deposits (so creation records v25 tracking).
contract AcceptingYieldModule is IYieldModule {
    uint256 public deposits;

    function initializeYield(uint256, address token, uint256 amount, YieldPreset) external override returns (uint256) {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        deposits++;
        return amount;
    }

    function unwindToEscrow(uint256, address token, uint256 principalExpected)
        external
        override
        returns (uint256, uint256)
    {
        IERC20(token).transfer(msg.sender, principalExpected);
        return (principalExpected, 0);
    }

    function emergencyUnwind(uint256, address token, uint256 principalExpected) external override returns (uint256) {
        IERC20(token).transfer(msg.sender, principalExpected);
        return principalExpected;
    }

    function canHandle(address, YieldPreset, uint256) external pure override returns (bool, bytes32) {
        return (true, bytes32(0));
    }

    function getModuleInfo() external pure override returns (string memory, string memory, bytes32) {
        return ('Accepting', '1.0.0', keccak256('accepting'));
    }
}

/// @notice Proves EscrowCreationPolicy preserves global semantics: one shared
///         policy authority affects creation through multiple independent escrow
///         products, and its changes apply consistently across them.
contract EscrowCreationPolicyTest is Test {
    EscrowCreationPolicy internal policy;
    AcceptingYieldModule internal yieldModule;
    YieldOps internal yieldOps;
    ModuleSnapshotRegistry internal mm;
    BondCollector internal bondCollector;
    DefaultResolutionModule internal resolutionModule;
    ERC20Mock internal token;

    EscrowVault internal escrowA;
    EscrowVault internal escrowB;

    address internal constant FEE = address(0xFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);

    function setUp() public {
        policy = new EscrowCreationPolicy(address(this));
        yieldModule = new AcceptingYieldModule();
        yieldOps = new YieldOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));
        bondCollector = new BondCollector(address(this));
        resolutionModule = new DefaultResolutionModule(address(this), address(0x1234));
        token = new ERC20Mock('Token', 'TKN', address(this), 0);
        token.mint(BUYER, 1_000 ether);

        escrowA = _deployEscrow();
        escrowB = _deployEscrow();

        vm.prank(BUYER);
        token.approve(address(escrowA), type(uint256).max);
        vm.prank(BUYER);
        token.approve(address(escrowB), type(uint256).max);
    }

    function _deployEscrow() internal returns (EscrowVault escrow) {
        escrow = new EscrowVault(0, FEE, address(yieldOps), address(mm));
        yieldOps.registerEscrowContract(address(escrow));
        mm.registerEscrowContract(address(escrow));
        bondCollector.registerEscrowContract(address(escrow));
        escrow.grantRole(escrow.ROLE_ADMIN_CONTRACT(), address(this));
        escrow.setCreationPolicy(address(policy));
        escrow.setBondCollector(address(bondCollector));
        escrow.setResolutionModule(address(resolutionModule));

        // Per-escrow YIELD_GEN override
        mm.queueModule(address(escrow), BaseEscrow.ModuleType.YIELD_GEN, address(yieldModule));
        vm.warp(block.timestamp + 8 days);
        mm.activateModule(address(escrow), BaseEscrow.ModuleType.YIELD_GEN);
    }

    function _settings(YieldPreset preset) internal pure returns (EscrowSettings memory s) {
        s = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: preset,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    function _create(EscrowVault escrow, YieldPreset preset) internal returns (uint256 id) {
        vm.prank(BUYER);
        id = escrow.createEscrow(address(token), SELLER, 100 ether, _settings(preset));
    }

    // ---- Role gates on the shared policy ----

    function test_policy_roleGates() public {
        // Unauthorized pause reverts
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(EscrowCreationPolicy.NotAuthorized.selector, address(0xBAD)));
        policy.pauseYieldDeposits('x');

        // Timelock can pause/resume
        policy.pauseYieldDeposits('emergency');
        assertTrue(policy.yieldDepositsPaused());
        vm.expectRevert(EscrowCreationPolicy.AlreadyPaused.selector);
        policy.pauseYieldDeposits('again');
        policy.resumeYieldDeposits();
        assertFalse(policy.yieldDepositsPaused());

        // Guardian can pause but not resume
        policy.grantRole(policy.ROLE_GUARDIAN(), address(0x6A6));
        vm.prank(address(0x6A6));
        policy.pauseYieldDeposits('guardian');
        assertTrue(policy.yieldDepositsPaused());
        vm.prank(address(0x6A6));
        vm.expectRevert();
        policy.resumeYieldDeposits();
    }

    // ---- Global yield-pause semantics across independent escrows ----

    function test_sharedYieldPause_affectsBothEscrows() public {
        // Baseline: policy not paused, yield preset ON → both record a deposit.
        uint256 a1 = _create(escrowA, YieldPreset.TO_SENDER);
        uint256 b1 = _create(escrowB, YieldPreset.TO_SENDER);
        assertTrue(escrowA.v25YieldModules(a1) != address(0), 'A should deposit when unpaused');
        assertTrue(escrowB.v25YieldModules(b1) != address(0), 'B should deposit when unpaused');

        // Pause once → both escrows stop depositing.
        policy.pauseYieldDeposits('emergency');
        uint256 a2 = _create(escrowA, YieldPreset.TO_SENDER);
        uint256 b2 = _create(escrowB, YieldPreset.TO_SENDER);
        assertEq(escrowA.v25YieldModules(a2), address(0), 'A should not deposit when paused');
        assertEq(escrowB.v25YieldModules(b2), address(0), 'B should not deposit when paused');

        // Resume once → both escrows deposit again.
        policy.resumeYieldDeposits();
        uint256 a3 = _create(escrowA, YieldPreset.TO_SENDER);
        uint256 b3 = _create(escrowB, YieldPreset.TO_SENDER);
        assertTrue(escrowA.v25YieldModules(a3) != address(0), 'A should deposit after resume');
        assertTrue(escrowB.v25YieldModules(b3) != address(0), 'B should deposit after resume');

        // Deposit count reflects the shared policy: 2 baseline + 2 resumed = 4.
        assertEq(yieldModule.deposits(), 4, 'deposit count');
    }

    // ---- Global resolver policy semantics across independent escrows ----

    function test_sharedResolverPolicy_appliesToBothEscrows() public {
        EscrowSettings memory withEoaResolver = EscrowSettings({
            customResolver: address(0xE0A),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Default: resolverMustBeContract == true → both reject an EOA resolver.
        assertTrue(policy.resolverMustBeContract(), 'default policy');
        vm.prank(BUYER);
        vm.expectRevert();
        escrowA.createEscrow(address(token), SELLER, 100 ether, withEoaResolver);
        vm.prank(BUYER);
        vm.expectRevert();
        escrowB.createEscrow(address(token), SELLER, 100 ether, withEoaResolver);

        // Flip once → both accept the same EOA resolver.
        policy.setResolverPolicy(false);
        vm.prank(BUYER);
        uint256 a = escrowA.createEscrow(address(token), SELLER, 100 ether, withEoaResolver);
        vm.prank(BUYER);
        uint256 b = escrowB.createEscrow(address(token), SELLER, 100 ether, withEoaResolver);

        (, , , address resolverA, , , , , , ) = escrowA.escrowTransfers(a);
        (, , , address resolverB, , , , , , ) = escrowB.escrowTransfers(b);
        assertEq(resolverA, address(0xE0A), 'A resolver');
        assertEq(resolverB, address(0xE0A), 'B resolver');
    }
}
