// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '@openzeppelin/contracts/governance/TimelockController.sol';
import '../contracts/core/SewCoreVault.sol';
import '../contracts/core/EscrowCreationPolicy.sol';
import '../contracts/core/ModuleSnapshotRegistry.sol';
import '../contracts/modules/DefaultResolutionModule.sol';
import '../contracts/modules/DefaultReleaseStrategy.sol';
import '../contracts/interfaces/IEscrowAppeal.sol';
import '../contracts/types/EscrowTypes.sol';
import '../contracts/types/YieldPresets.sol';


import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract ERC20Mock is ERC20 {
    constructor(string memory name_, string memory symbol_, address initialAccount, uint256 initialBalance) ERC20(name_, symbol_) {
        _mint(initialAccount, initialBalance);
    }
}

contract MockRevertingERC20 is ERC20 {
    bool public shouldRevert;
    constructor(string memory name_, string memory symbol_, address initialAccount, uint256 initialBalance) ERC20(name_, symbol_) {
        _mint(initialAccount, initialBalance);
    }
    function setShouldRevert(bool value) external { shouldRevert = value; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!shouldRevert, 'MockRevertingERC20: Transfer reverted');
        return super.transfer(to, amount);
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!shouldRevert, 'MockRevertingERC20: TransferFrom reverted');
        return super.transferFrom(from, to, amount);
    }
}

contract FeeOnTransferERC20 is ERC20 {
    constructor(address initialAccount, uint256 initialBalance) ERC20('Fee token', 'FEE') {
        _mint(initialAccount, initialBalance);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, to, value - fee);
            super._update(from, address(0), fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract BonusTransferERC20 is ERC20 {
    constructor(address initialAccount, uint256 initialBalance) ERC20('Bonus token', 'BONUS') {
        _mint(initialAccount, initialBalance);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) super._update(address(0), to, 1);
    }
}

contract SewCoreVaultProfileTest is Test {
    SewCoreVault internal vault;
    ModuleSnapshotRegistry internal registry;
    EscrowCreationPolicy internal policy;
    DefaultResolutionModule internal resolution;
    ERC20Mock internal token;
    DefaultReleaseStrategy internal releaseStrategy;
    uint256 internal timelockNonce;

    address internal constant BUYER = address(0xB0B);
    address internal constant SELLER = address(0x5E11E7);
    address internal constant RESOLVER = address(0xA11CE);
    address internal constant FEE = address(0xFEE);
    address internal constant GUARDIAN = address(0x6A4D);
    uint256 internal constant AMOUNT = 10_000 ether;

    function setUp() public {
        registry = new ModuleSnapshotRegistry(address(this));
        policy = new EscrowCreationPolicy(address(this));
        resolution = new DefaultResolutionModule(address(this), RESOLVER);
        releaseStrategy = new DefaultReleaseStrategy();
        token = new ERC20Mock('Sew test token', 'STT', address(this), 1_000_000 ether);
        vault = new SewCoreVault(0, FEE, address(registry), address(token));

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setMinDisputeEscrowValue(1);
        vault.setMaxDisputesPerSenderPerDay(10);
        vault.setCreationPolicy(address(policy));
        registry.registerEscrowContract(address(vault));
        registry.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        registry.queueModule(address(vault), BaseEscrow.ModuleType.RESOLUTION, address(resolution));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);
        registry.activateModule(address(vault), BaseEscrow.ModuleType.RESOLUTION);

        token.transfer(BUYER, 100_000 ether);
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(BUYER);
        id = vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
    }

    function _vaultForToken(address supportedToken) internal returns (SewCoreVault testVault) {
        testVault = new SewCoreVault(0, FEE, address(registry), supportedToken);
        testVault.grantRole(testVault.ROLE_ADMIN_CONTRACT(), address(this));
        testVault.setCreationPolicy(address(policy));
        registry.registerEscrowContract(address(testVault));
        registry.queueModule(address(testVault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        registry.queueModule(address(testVault), BaseEscrow.ModuleType.RESOLUTION, address(resolution));
        vm.warp(block.timestamp + 8 days);
        registry.activateModule(address(testVault), BaseEscrow.ModuleType.RELEASE);
        registry.activateModule(address(testVault), BaseEscrow.ModuleType.RESOLUTION);
    }

    function _settings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    function test_initial_configuration_is_explicit_and_observable() public {
        assertEq(vault.supportedToken(), address(token));
        assertEq(vault.escrowFee(), 0);
        assertEq(vault.escrowFeeAddress(), FEE);
        assertEq(vault.yieldProtocolFeeBps(), 0);
        assertEq(vault.appealBondProtocolFeeBps(), 0);
        assertEq(vault.minDisputeEscrowValue(), 1);
        assertEq(vault.maxDisputesPerSenderPerDay(), 10);
        (uint256 defaultRelease, uint256 defaultCancel, uint256 maxDispute, uint256 appealWindow) = vault.timeoutConfig();
        assertEq(defaultRelease, 0);
        assertEq(defaultCancel, 0);
        assertEq(maxDispute, 90 days);
        assertEq(appealWindow, 0);
        assertEq(address(registry.getDefaultReleaseStrategy(address(vault))), address(releaseStrategy));
        assertEq(address(registry.getDefaultResolutionModule(address(vault))), address(resolution));
        assertEq(address(registry.getDefaultCancellationStrategy(address(vault))), address(0));
        assertEq(address(registry.getDefaultYieldGenerationModule(address(vault))), address(0));
        assertEq(vault.disputeResolutionModule(), address(0), 'resolution authority comes from the activated snapshot registry');
        (bool resolverAuthorized,) = resolution.isAuthorizedDisputeResolver(0, address(vault), RESOLVER, '');
        assertTrue(resolverAuthorized);
        (uint256 requiredBond, address bondToken) = resolution.getRequiredAppealBond(0, address(vault), 0, '');
        assertEq(requiredBond, 0);
        assertEq(bondToken, address(0));
        assertFalse(vault.paused());
    }

    function test_governance_handoff_guardian_bounds_and_timelock_liveness() public {
        TimelockController timelock = new TimelockController(0, _one(address(this)), _one(address(0)), address(0));
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(timelock));
        vault.grantRole(vault.ROLE_TIMELOCK(), address(timelock));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(timelock));
        vault.grantRole(vault.ROLE_GUARDIAN(), GUARDIAN);

        // Verify successor authority before removing every deployer control path.
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(vault.hasRole(vault.ROLE_TIMELOCK(), address(timelock)));
        assertTrue(vault.hasRole(vault.ROLE_ADMIN_CONTRACT(), address(timelock)));
        vault.revokeRole(vault.ROLE_TIMELOCK(), address(this));
        vault.revokeRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), address(this));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(vault.hasRole(vault.ROLE_TIMELOCK(), address(this)));
        assertFalse(vault.hasRole(vault.ROLE_ADMIN_CONTRACT(), address(this)));

        uint256 existingEscrow = _create();
        uint256 existingDisputableEscrow = _create();
        vm.expectRevert();
        vault.setEscrowFeeBps(50);
        vm.prank(GUARDIAN);
        vault.pause('incident');
        assertTrue(vault.paused());
        vm.prank(BUYER);
        vm.expectRevert();
        vault.createEscrow(address(token), SELLER, AMOUNT, _settings());
        vm.prank(BUYER);
        vault.raiseDispute(existingDisputableEscrow);
        assertEq(uint8(vault.getEscrowState(existingDisputableEscrow)), uint8(EscrowState.DISPUTED), 'pause preserves dispute access for existing escrows');
        vm.prank(BUYER);
        vault.release(existingEscrow);
        vm.prank(SELLER);
        vault.withdrawEscrow(existingEscrow);
        assertEq(token.balanceOf(SELLER), AMOUNT, 'guardian pause preserves settlement of existing escrows');
        vm.prank(GUARDIAN);
        vm.expectRevert();
        vault.setEscrowFeeBps(50);

        bytes memory feeChange = abi.encodeCall(vault.setEscrowFeeBps, (50));
        bytes32 salt = keccak256('sew-core-governance-live');
        timelock.schedule(address(vault), 0, feeChange, bytes32(0), salt, 0);
        timelock.execute(address(vault), 0, feeChange, bytes32(0), salt);
        assertEq(vault.escrowFee(), 50);

        bytes memory resume = abi.encodeCall(vault.unpause, ());
        bytes32 resumeSalt = keccak256('sew-core-resume-live');
        timelock.schedule(address(vault), 0, resume, bytes32(0), resumeSalt, 0);
        timelock.execute(address(vault), 0, resume, bytes32(0), resumeSalt);
        assertFalse(vault.paused());
    }

    function test_timelock_controls_the_complete_deployment_graph_and_slow_lane() public {
        TimelockController timelock = new TimelockController(0, _one(address(this)), _one(address(this)), address(0));
        ModuleSnapshotRegistry governedRegistry = new ModuleSnapshotRegistry(address(timelock));
        EscrowCreationPolicy governedPolicy = new EscrowCreationPolicy(address(timelock));
        DefaultResolutionModule governedResolution = new DefaultResolutionModule(address(timelock), RESOLVER);
        DefaultReleaseStrategy governedRelease = new DefaultReleaseStrategy();
        SewCoreVault governedVault = new SewCoreVault(0, FEE, address(governedRegistry), address(token));

        assertTrue(governedRegistry.hasRole(governedRegistry.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(governedRegistry.hasRole(governedRegistry.ROLE_TIMELOCK(), address(timelock)));
        assertTrue(governedPolicy.hasRole(governedPolicy.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(governedPolicy.hasRole(governedPolicy.ROLE_TIMELOCK(), address(timelock)));
        assertTrue(governedResolution.hasRole(governedResolution.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(governedVault.hasRole(governedVault.DEFAULT_ADMIN_ROLE(), address(timelock)));

        // The deployer seeds successor vault authority; later actions must go
        // through that authority rather than relying on a still-privileged EOA.
        governedVault.grantRole(governedVault.DEFAULT_ADMIN_ROLE(), address(timelock));
        governedVault.grantRole(governedVault.ROLE_TIMELOCK(), address(timelock));
        _execute(timelock, address(governedVault), abi.encodeCall(governedVault.grantRole,
            (governedVault.ROLE_ADMIN_CONTRACT(), address(timelock))));
        _execute(timelock, address(governedVault), abi.encodeCall(governedVault.grantRole,
            (governedVault.ROLE_GUARDIAN(), GUARDIAN)));
        _execute(timelock, address(governedVault), abi.encodeCall(governedVault.grantRole,
            (governedVault.ROLE_FEE_RECIPIENT(), FEE)));
        _execute(timelock, address(governedVault), abi.encodeCall(governedVault.setCreationPolicy,
            (address(governedPolicy))));
        _execute(timelock, address(governedResolution), abi.encodeWithSignature(
            'grantRole(bytes32,address)', governedResolution.ROLE_TIMELOCK(), address(timelock)));
        _execute(timelock, address(governedRegistry), abi.encodeCall(governedRegistry.registerEscrowContract,
            (address(governedVault))));
        _execute(timelock, address(governedRegistry), abi.encodeCall(governedRegistry.queueModule,
            (address(governedVault), BaseEscrow.ModuleType.RELEASE, address(governedRelease))));
        _execute(timelock, address(governedRegistry), abi.encodeCall(governedRegistry.queueModule,
            (address(governedVault), BaseEscrow.ModuleType.RESOLUTION, address(governedResolution))));
        vm.warp(block.timestamp + 7 days + 1);
        _execute(timelock, address(governedRegistry), abi.encodeCall(governedRegistry.activateModule,
            (address(governedVault), BaseEscrow.ModuleType.RELEASE)));
        _execute(timelock, address(governedRegistry), abi.encodeCall(governedRegistry.activateModule,
            (address(governedVault), BaseEscrow.ModuleType.RESOLUTION)));

        assertEq(address(governedRegistry.getDefaultReleaseStrategy(address(governedVault))), address(governedRelease));
        assertEq(address(governedRegistry.getDefaultResolutionModule(address(governedVault))), address(governedResolution));
        assertEq(address(governedVault.creationPolicy()), address(governedPolicy));
        assertEq(governedResolution.resolver(), RESOLVER);
        assertTrue(governedVault.hasRole(governedVault.ROLE_GUARDIAN(), GUARDIAN));
        assertTrue(governedVault.hasRole(governedVault.ROLE_FEE_RECIPIENT(), FEE));

        governedVault.revokeRole(governedVault.ROLE_ADMIN_CONTRACT(), address(this));
        governedVault.revokeRole(governedVault.ROLE_TIMELOCK(), address(this));
        governedVault.revokeRole(governedVault.DEFAULT_ADMIN_ROLE(), address(this));
        assertFalse(governedVault.hasRole(governedVault.ROLE_ADMIN_CONTRACT(), address(this)));
        assertFalse(governedVault.hasRole(governedVault.ROLE_TIMELOCK(), address(this)));
        assertFalse(governedVault.hasRole(governedVault.DEFAULT_ADMIN_ROLE(), address(this)));

        _execute(timelock, address(governedVault), abi.encodeCall(governedVault.setEscrowFeeBps, (25)));
        _execute(timelock, address(governedResolution), abi.encodeCall(governedResolution.setResolver, (address(0xBEEF))));
        assertEq(governedVault.escrowFee(), 25);
        assertEq(governedResolution.resolver(), address(0xBEEF));
    }

    function _one(address account) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = account;
    }

    function _execute(TimelockController timelock, address target, bytes memory data) private {
        bytes32 salt = keccak256(abi.encode('sew-core-governed-bootstrap', timelockNonce++));
        timelock.schedule(target, 0, data, bytes32(0), salt, 0);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function test_create_release_and_pull_settlement_conserves_fee() public {
        vault.setEscrowFeeBps(100);
        uint256 id = _create();
        uint256 fee = AMOUNT / 100;
        uint256 net = AMOUNT - fee;
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), net);
        assertEq(vault.totalFeesPerToken(address(token)), fee);
        assertEq(token.balanceOf(address(vault)), AMOUNT);
        (
            address snapResolution,
            address snapRelease,
            address snapCancellation,
            address snapYield,
            ,
            uint256 snapYieldFee,
            uint256 snapAppealFee,
            uint256 snapEscrowFee,
            uint256 snapAutoRelease,
            uint256 snapAutoCancel,
            uint256 snapMaxDispute,
            uint256 snapAppealWindow
        ) = vault.moduleSnapshots(id);
        assertEq(snapResolution, address(resolution));
        assertEq(snapRelease, address(releaseStrategy));
        assertEq(snapCancellation, address(0));
        assertEq(snapYield, address(0));
        assertEq(snapYieldFee, 0);
        assertEq(snapAppealFee, 0);
        assertEq(snapEscrowFee, 100);
        assertEq(snapAutoRelease, 0);
        assertEq(snapAutoCancel, 0);
        assertEq(snapMaxDispute, 90 days);
        assertEq(snapAppealWindow, 0);

        vm.prank(BUYER);
        vault.release(id);
        vm.prank(BUYER);
        vm.expectRevert();
        vault.release(id);
        assertEq(vault.claimableBalances(id, SELLER), net);
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0);
        assertEq(token.balanceOf(SELLER), 0, 'settlement is pull based');

        vm.prank(address(0xBAD));
        vm.expectRevert();
        vault.withdrawEscrow(id);
        assertEq(vault.claimableBalances(id, SELLER), net, 'failed unauthorized withdrawal preserves claim');
        vm.prank(SELLER);
        assertEq(vault.withdrawEscrow(id), net);
        vm.prank(SELLER);
        vm.expectRevert();
        vault.withdrawEscrow(id);
        assertEq(token.balanceOf(SELLER), net);
        assertEq(token.balanceOf(address(vault)), fee);
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), address(this));
        vault.withdrawFees(address(token));
        assertEq(token.balanceOf(FEE), fee);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_zero_fee_path_and_failed_transfer_recovery() public {
        vault.setEscrowFeeBps(0);
        uint256 noFeeId = _create();
        assertEq(vault.totalFeesPerToken(address(token)), 0);
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), AMOUNT);
        vm.prank(BUYER);
        vault.release(noFeeId);
        assertEq(vault.claimableBalances(noFeeId, SELLER), AMOUNT);
        MockRevertingERC20 flaky = new MockRevertingERC20('Flaky', 'FLK', address(this), AMOUNT);
        SewCoreVault flakyVault = _vaultForToken(address(flaky));
        flakyVault.setEscrowFeeBps(100);
        flaky.transfer(BUYER, AMOUNT);
        vm.prank(BUYER);
        flaky.approve(address(flakyVault), AMOUNT);
        EscrowSettings memory settings = _settings();
        vm.prank(BUYER);
        uint256 id = flakyVault.createEscrow(address(flaky), SELLER, AMOUNT, settings);
        vm.prank(BUYER);
        flakyVault.release(id);

        uint256 net = AMOUNT - AMOUNT / 100;
        flaky.setShouldRevert(true);
        vm.prank(SELLER);
        vm.expectRevert();
        flakyVault.withdrawEscrow(id);
        assertEq(flakyVault.claimableBalances(id, SELLER), net, 'failed transfer restores entitlement');
        assertEq(flakyVault.totalClaimableAssets(address(flaky)), net);
        assertEq(flaky.balanceOf(address(flakyVault)), AMOUNT);
        flaky.setShouldRevert(false);
        vm.prank(SELLER);
        flakyVault.withdrawEscrow(id);
        assertEq(flaky.balanceOf(SELLER), net);
    }

    function test_fee_on_transfer_token_is_rejected_without_creating_liabilities() public {
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20(BUYER, AMOUNT);
        SewCoreVault taxVault = _vaultForToken(address(taxed));
        vm.prank(BUYER);
        taxed.approve(address(taxVault), AMOUNT);
        uint256 buyerBalanceBefore = taxed.balanceOf(BUYER);

        vm.prank(BUYER);
        vm.expectRevert();
        taxVault.createEscrow(address(taxed), SELLER, AMOUNT, _settings());

        assertEq(taxed.balanceOf(BUYER), buyerBalanceBefore, 'reverted transfer restores the buyer balance');
        assertEq(taxed.balanceOf(address(taxVault)), 0, 'reverted transfer leaves no tokens in custody');
        assertEq(taxVault.totalHeldInEscrowPerToken(address(taxed)), 0, 'no principal liability is recorded');
    }

    function test_bonus_transfer_token_is_rejected_without_creating_liabilities() public {
        BonusTransferERC20 bonus = new BonusTransferERC20(address(this), 100_000 ether);
        SewCoreVault bonusVault = _vaultForToken(address(bonus));
        bonus.transfer(BUYER, AMOUNT);
        vm.prank(BUYER);
        bonus.approve(address(bonusVault), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(
            EscrowCreation.UnexpectedTokenReceipt.selector, address(bonus), AMOUNT, AMOUNT + 1
        ));
        vm.prank(BUYER);
        bonusVault.createEscrow(address(bonus), SELLER, AMOUNT, _settings());

        assertEq(bonusVault.getEscrowCount(), 0);
        assertEq(bonusVault.totalHeldInEscrowPerToken(address(bonus)), 0);
    }

    function test_bilateral_cancel_refunds_sender_without_deployer() public {
        vault.setEscrowFeeBps(100);
        uint256 id = _create();
        vm.prank(SELLER);
        vault.recipientCancel(id);
        vm.prank(BUYER);
        vault.senderCancel(id);

        assertEq(vault.claimableBalances(id, BUYER), AMOUNT - AMOUNT / 100);
        vm.prank(BUYER);
        vault.withdrawEscrow(id);
        assertEq(token.balanceOf(BUYER), 100_000 ether - AMOUNT + (AMOUNT - AMOUNT / 100));
    }

    function test_single_resolver_dispute_settles_immediately_without_appeal_path() public {
        uint256 id = _create();
        vm.prank(BUYER);
        vault.raiseDispute(id);
        address assignedResolver;
        (,,, assignedResolver,,,,,,) = vault.escrowTransfers(id);
        assertEq(assignedResolver, RESOLVER);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        vault.releaseAsDisputeResolver(id, keccak256('unauthorized'));
        vm.prank(RESOLVER);
        vault.releaseAsDisputeResolver(id, keccak256('resolution'));
        assertEq(uint8(vault.getEscrowState(id)), uint8(EscrowState.RELEASED));
        (bool pending, , , ) = vault.pendingSettlements(id);
        assertFalse(pending, 'single-resolver profile has no appeal queue');
        assertEq(vault.claimableBalances(id, SELLER), AMOUNT);
    }

    function test_timeout_refunds_after_max_dispute_duration() public {
        uint256 id = _create();
        vm.prank(BUYER);
        vault.raiseDispute(id);
        vm.warp(block.timestamp + 90 days + 1);
        vm.prank(BUYER);
        vault.resolveDisputeByTimeout(id);
        assertEq(uint8(vault.getEscrowState(id)), uint8(EscrowState.REFUNDED));
        assertEq(vault.claimableBalances(id, BUYER), AMOUNT);
    }

    function test_nonselected_features_are_not_advertised_or_operable() public {
        assertFalse(vault.supportsInterface(type(IEscrowAppeal).interfaceId));
        (bool appealCall,) = address(vault).call(abi.encodeWithSignature('escalateDispute(uint256)', 0));
        assertFalse(appealCall, 'appeal selector is absent from Sew core');
        (bool splitCall,) = address(vault).call(abi.encodeWithSignature('proposeSplit(uint256,uint256,uint256,uint64)', 0, 1, 1, 0));
        assertFalse(splitCall, 'split selector is absent from Sew core');

        ERC20Mock unsupported = new ERC20Mock('Unsupported', 'NOPE', BUYER, AMOUNT);
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(SewCoreVault.UnsupportedToken.selector, address(unsupported)));
        vault.createEscrow(address(unsupported), SELLER, AMOUNT, _settings());

        EscrowSettings memory customResolverSettings = _settings();
        customResolverSettings.customResolver = address(releaseStrategy);
        vm.prank(BUYER);
        vm.expectRevert(SewCoreVault.CoreFeatureDisabled.selector);
        vault.createEscrow(address(token), SELLER, AMOUNT, customResolverSettings);
    }

    function test_yield_opt_in_is_rejected() public {
        EscrowSettings memory s = _settings();
        s.yieldPreset = YieldPreset.ENABLED;
        vm.prank(BUYER);
        vm.expectRevert();
        vault.createEscrow(address(token), SELLER, AMOUNT, s);
    }
}
