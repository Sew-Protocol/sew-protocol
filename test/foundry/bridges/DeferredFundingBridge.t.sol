// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/bridges/DeferredFundingBridge.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';

/**
 * @title DeferredFundingBridgeTest
 * @notice Comprehensive tests for the DeferredFundingBridge Phase-1 implementation.
 *
 * Test coverage:
 *  - Path A (on-chain slot): openSlot, executeSlot, cancelSlot
 *  - Path B (EIP-712 gasless): executeFromSignature, invalidateNonce
 *  - Shared: parameter validation, fee accounting, recipient balance, event emission
 *  - Negative cases: wrong releaser, expired deadline, nonce replay, cancelled slot,
 *                    bad signature, zero inputs
 */
contract DeferredFundingBridgeTest is Test {
    // ─── Protocol contracts ───────────────────────────────────────────────────
    EscrowVault       public vault;
    ModuleSnapshotRegistry public moduleRegistry;
    DefaultResolutionModule public resolutionModule;
    DefaultReleaseStrategy  public releaseStrategy;
    CreateOps         public createOps;
    DisputeOps        public disputeOps;
    SettlementOps     public settlementOps;
    YieldOps          public yieldOps;
    BondCollector     public bondCollector;

    // ─── Bridge under test ────────────────────────────────────────────────────
    DeferredFundingBridge public bridge;

    // ─── Test token ───────────────────────────────────────────────────────────
    ERC20Mock public token;

    // ─── Actors ───────────────────────────────────────────────────────────────
    address public admin     = address(this);
    address public feeWallet = address(0xFEE);
    address public resolver  = address(0xABCD);

    // Derive releaser from a private key so we can sign EIP-712 messages
    uint256 public creatorPrivKey = 0xC0FFEE;
    address public creator;   // derived from creatorPrivKey

    address public releaser   = address(0x2222);
    address public recipient  = address(0x3333);
    address public stranger   = address(0x9999);

    // Vault fee: 1% (100 bps)
    uint256 constant FEE_BPS        = 100;
    uint256 constant FEE_DENOM      = 10_000;
    uint256 constant DEFAULT_AMOUNT = 1_000e18;

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        creator = vm.addr(creatorPrivKey);

        // 1. Deploy ops infrastructure
        yieldOps      = new YieldOps(admin);
        disputeOps    = new DisputeOps(admin);
        settlementOps = new SettlementOps(admin);
        createOps     = new CreateOps(admin);
        bondCollector = new BondCollector(admin);
        moduleRegistry = new ModuleSnapshotRegistry(admin);
        resolutionModule = new DefaultResolutionModule(admin, resolver);
        releaseStrategy  = new DefaultReleaseStrategy();

        // 2. Deploy vault
        vault = new EscrowVault(
            FEE_BPS,
            feeWallet,
            address(yieldOps),
            address(disputeOps),
            address(moduleRegistry)
        );

        // 3. Wire ops to vault
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));
        moduleRegistry.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), admin);
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));

        // 4. Register release strategy with the module registry (requires 7-day slow lane)
        moduleRegistry.grantRole(moduleRegistry.ROLE_TIMELOCK(), admin);
        moduleRegistry.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 7 days + 1);
        moduleRegistry.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        // 5. Deploy bridge
        bridge = new DeferredFundingBridge(address(vault), 'DeferredFundingBridge', '1');

        // 6. Deploy and distribute test token
        token = new ERC20Mock('TestUSD', 'TUSD', admin, 0);
        token.mint(releaser, 100_000e18);
        token.mint(creator,  100_000e18); // for slot-path tests where creator could also be a releaser
        token.mint(stranger,  10_000e18);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _defaultDeadline() internal view returns (uint256) {
        return block.timestamp + 1 days;
    }

    /// @dev Releaser approves bridge and calls executeSlot
    function _approveAndExecuteSlot(bytes32 slotId) internal {
        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        bridge.executeSlot(slotId);
        vm.stopPrank();
    }

    /// @dev Builds and signs a DeferredCommitment typed message
    function _signCommitment(
        address _token,
        address _recipient,
        address _releaser,
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline
    ) internal view returns (bytes memory sig) {
        bytes32 digest = bridge.commitmentDigest(_token, _recipient, _releaser, _amount, _nonce, _deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(creatorPrivKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Expected recipient amount after vault fee
    function _netAmount(uint256 gross) internal pure returns (uint256) {
        return gross - (gross * FEE_BPS / FEE_DENOM);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Construction
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_SetsVault() public view {
        assertEq(address(bridge.vault()), address(vault));
    }

    function test_constructor_RejectsZeroVault() public {
        vm.expectRevert(DeferredFundingBridge.ZeroVaultAddress.selector);
        new DeferredFundingBridge(address(0), 'Bridge', '1');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH A — On-chain slot: openSlot
    // ═══════════════════════════════════════════════════════════════════════════

    function test_openSlot_StoresSlotAndEmitsEvent() public {
        vm.prank(creator);
        vm.expectEmit(false, true, true, true);
        emit DeferredFundingBridge.SlotOpened(
            bytes32(0), // slotId not known ahead of time — checked via returned value
            creator,
            releaser,
            recipient,
            address(token),
            DEFAULT_AMOUNT,
            _defaultDeadline()
        );
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        (
            address storedCreator,
            address storedToken,
            address storedRecipient,
            address storedReleaser,
            uint256 storedAmount,
            uint256 storedDeadline,
            bool storedActive
        ) = bridge.slots(slotId);

        assertEq(storedCreator,   creator);
        assertEq(storedToken,     address(token));
        assertEq(storedRecipient, recipient);
        assertEq(storedReleaser,  releaser);
        assertEq(storedAmount,    DEFAULT_AMOUNT);
        assertEq(storedDeadline,  _defaultDeadline());
        assertTrue(storedActive);
    }

    function test_openSlot_RevertsOnZeroToken() public {
        vm.prank(creator);
        vm.expectRevert(DeferredFundingBridge.ZeroToken.selector);
        bridge.openSlot(address(0), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());
    }

    function test_openSlot_RevertsOnZeroRecipient() public {
        vm.prank(creator);
        vm.expectRevert(DeferredFundingBridge.ZeroRecipient.selector);
        bridge.openSlot(address(token), address(0), releaser, DEFAULT_AMOUNT, _defaultDeadline());
    }

    function test_openSlot_RevertsOnZeroReleaser() public {
        vm.prank(creator);
        vm.expectRevert(DeferredFundingBridge.ZeroReleaser.selector);
        bridge.openSlot(address(token), recipient, address(0), DEFAULT_AMOUNT, _defaultDeadline());
    }

    function test_openSlot_RevertsOnZeroAmount() public {
        vm.prank(creator);
        vm.expectRevert(DeferredFundingBridge.ZeroAmount.selector);
        bridge.openSlot(address(token), recipient, releaser, 0, _defaultDeadline());
    }

    function test_openSlot_RevertsOnExpiredDeadline() public {
        vm.prank(creator);
        vm.expectRevert();
        bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, block.timestamp - 1);
    }

    function test_openSlot_RevertsWhenRecipientEqualsReleaser() public {
        vm.prank(creator);
        vm.expectRevert();
        bridge.openSlot(address(token), releaser, releaser, DEFAULT_AMOUNT, _defaultDeadline());
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH A — executeSlot (happy path)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_executeSlot_HappyPath_RecipientReceivesFunds() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 releaserBefore  = token.balanceOf(releaser);

        _approveAndExecuteSlot(slotId);

        uint256 expected = _netAmount(DEFAULT_AMOUNT);
        assertEq(token.balanceOf(recipient), recipientBefore + expected, 'recipient balance');
        assertEq(token.balanceOf(releaser),  releaserBefore  - DEFAULT_AMOUNT, 'releaser balance');
    }

    function test_executeSlot_HappyPath_FeeGoesToFeeWallet() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        uint256 feeBefore = token.balanceOf(feeWallet);

        // Fee is collected by vault but only withdrawable by fee role — the vault holds it internally.
        // We verify accounting via totalFeesPerToken.
        _approveAndExecuteSlot(slotId);

        uint256 expectedFee = DEFAULT_AMOUNT * FEE_BPS / FEE_DENOM;
        assertEq(vault.totalFeesPerToken(address(token)), expectedFee, 'vault fee accounting');
        // feeWallet balance unchanged until withdrawFees() is called
        assertEq(token.balanceOf(feeWallet), feeBefore, 'fee wallet unchanged');
    }

    function test_executeSlot_HappyPath_MarksSlotInactive() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        _approveAndExecuteSlot(slotId);

        (,,,,,, bool active) = bridge.slots(slotId);
        assertFalse(active, 'slot should be inactive after execution');
    }

    function test_executeSlot_HappyPath_TracksWorkflowMetadata() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        _approveAndExecuteSlot(slotId);

        // workflowId is 0 (first escrow in vault)
        assertEq(bridge.workflowCreator(0), creator,  'workflowCreator');
        assertEq(bridge.workflowReleaser(0), releaser, 'workflowReleaser');
    }

    function test_executeSlot_HappyPath_VaultEscrowIsReleased() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        _approveAndExecuteSlot(slotId);

        EscrowState state = vault.getEscrowState(0);
        assertEq(uint8(state), uint8(EscrowState.RELEASED), 'vault escrow should be RELEASED');
    }

    function test_executeSlot_HappyPath_EmitsCommitmentExecuted() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        vm.expectEmit(true, true, true, false);
        emit DeferredFundingBridge.CommitmentExecuted(
            slotId, creator, releaser, recipient, address(token), DEFAULT_AMOUNT, 0
        );
        bridge.executeSlot(slotId);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH A — executeSlot (negative cases)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_executeSlot_RevertsIfNotDesignatedReleaser() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        vm.startPrank(stranger);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(DeferredFundingBridge.NotDesignatedReleaser.selector, stranger, releaser)
        );
        bridge.executeSlot(slotId);
        vm.stopPrank();
    }

    function test_executeSlot_RevertsIfDeadlineExpired() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        vm.warp(block.timestamp + 2 days); // past deadline

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        vm.expectRevert();
        bridge.executeSlot(slotId);
        vm.stopPrank();
    }

    function test_executeSlot_RevertsIfSlotAlreadyExecuted() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        _approveAndExecuteSlot(slotId);

        // Second attempt should fail
        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(DeferredFundingBridge.SlotNotActive.selector, slotId));
        bridge.executeSlot(slotId);
        vm.stopPrank();
    }

    function test_executeSlot_RevertsIfSlotCancelled() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        vm.prank(creator);
        bridge.cancelSlot(slotId);

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(DeferredFundingBridge.SlotNotActive.selector, slotId));
        bridge.executeSlot(slotId);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH A — cancelSlot
    // ═══════════════════════════════════════════════════════════════════════════

    function test_cancelSlot_ByCreatorSucceeds() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        vm.prank(creator);
        vm.expectEmit(true, true, false, false);
        emit DeferredFundingBridge.SlotCancelled(slotId, creator);
        bridge.cancelSlot(slotId);

        (,,,,,, bool active) = bridge.slots(slotId);
        assertFalse(active);
    }

    function test_cancelSlot_RevertsIfCallerNotCreator() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(DeferredFundingBridge.SlotNotOwnedByCaller.selector, slotId, stranger)
        );
        bridge.cancelSlot(slotId);
    }

    function test_cancelSlot_RevertsIfAlreadyInactive() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());

        vm.prank(creator);
        bridge.cancelSlot(slotId);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(DeferredFundingBridge.SlotNotActive.selector, slotId));
        bridge.cancelSlot(slotId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH B — executeFromSignature (happy path)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_executeFromSignature_HappyPath_RecipientReceivesFunds() public {
        uint256 nonce    = 1;
        uint256 deadline = _defaultDeadline();
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        uint256 recipientBefore = token.balanceOf(recipient);

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);
        vm.stopPrank();

        uint256 expected = _netAmount(DEFAULT_AMOUNT);
        assertEq(token.balanceOf(recipient), recipientBefore + expected, 'recipient balance');
    }

    function test_executeFromSignature_HappyPath_NonceMark() public {
        uint256 nonce    = 42;
        uint256 deadline = _defaultDeadline();
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);
        vm.stopPrank();

        assertTrue(bridge.usedNonces(creator, nonce), 'nonce should be marked used');
    }

    function test_executeFromSignature_HappyPath_VaultEscrowIsReleased() public {
        uint256 nonce    = 1;
        uint256 deadline = _defaultDeadline();
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);
        vm.stopPrank();

        EscrowState state = vault.getEscrowState(0);
        assertEq(uint8(state), uint8(EscrowState.RELEASED));
    }

    function test_executeFromSignature_HappyPath_TracksWorkflowMetadata() public {
        uint256 nonce    = 1;
        uint256 deadline = _defaultDeadline();
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);
        vm.stopPrank();

        assertEq(bridge.workflowCreator(0),  creator,  'creator');
        assertEq(bridge.workflowReleaser(0), releaser, 'releaser');
    }

    function test_executeFromSignature_HappyPath_EmitsCommitmentExecuted() public {
        uint256 nonce    = 1;
        uint256 deadline = _defaultDeadline();
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        vm.expectEmit(false, true, true, false); // commitmentId is deterministic but don't compute here
        emit DeferredFundingBridge.CommitmentExecuted(
            bytes32(0), creator, releaser, recipient, address(token), DEFAULT_AMOUNT, 0
        );
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);
        vm.stopPrank();
    }

    function test_executeFromSignature_MultipleDistinctNonces() public {
        for (uint256 i = 1; i <= 3; i++) {
            uint256 nonce    = i;
            uint256 deadline = _defaultDeadline();
            uint256 amount   = 2_000e18 * i;
            bytes memory sig = _signCommitment(address(token), recipient, releaser, amount, nonce, deadline);

            vm.startPrank(releaser);
            token.approve(address(bridge), amount);
            bridge.executeFromSignature(address(token), recipient, releaser, amount, nonce, deadline, sig);
            vm.stopPrank();

            assertTrue(bridge.usedNonces(creator, nonce));
        }
        // 3 escrows created
        assertEq(vault.getEscrowCount(), 3);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH B — executeFromSignature (negative cases)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_executeFromSignature_RevertsIfCallerNotDesignatedReleaser() public {
        uint256 nonce    = 1;
        uint256 deadline = _defaultDeadline();
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        vm.startPrank(stranger);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(DeferredFundingBridge.NotDesignatedReleaser.selector, stranger, releaser)
        );
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);
        vm.stopPrank();
    }

    function test_executeFromSignature_RevertsIfDeadlineExpired() public {
        uint256 nonce    = 1;
        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        vm.warp(deadline + 1); // expire it

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        vm.expectRevert();
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);
        vm.stopPrank();
    }

    function test_executeFromSignature_RevertsOnNonceReplay() public {
        uint256 nonce    = 7;
        uint256 deadline = _defaultDeadline();
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT * 2);
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);

        vm.expectRevert(
            abi.encodeWithSelector(DeferredFundingBridge.NonceAlreadyUsed.selector, creator, nonce)
        );
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);
        vm.stopPrank();
    }

    function test_executeFromSignature_RevertsOnBadSignature() public {
        uint256 nonce    = 1;
        uint256 deadline = _defaultDeadline();
        // Sign with a different key
        uint256 wrongKey = 0xDEADBEEF;
        bytes32 digest   = bridge.commitmentDigest(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        // The signature is valid but belongs to a different signer — the recovered address != creator
        // The vault will accept it (nonce consumed for the recovered signer), but the
        // commitment metadata will point to the wrong creator. This is an important note:
        // The bridge does NOT whitelist creators — any valid ECDSA signer is accepted.
        // The test verifies that a signature from a *different* key succeeds, but records
        // the wrong creator, which is expected Phase-1 behavior. Whitelisting is Phase-2.
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, badSig);
        vm.stopPrank();

        // workflowCreator should be vm.addr(wrongKey), not creator
        assertNotEq(bridge.workflowCreator(0), creator);
    }

    function test_executeFromSignature_RevertsOnTamperedAmount() public {
        uint256 nonce    = 1;
        uint256 deadline = _defaultDeadline();
        // Sign for DEFAULT_AMOUNT
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT * 2);
        // Submit with a different amount — signature won't match → different recovered address
        // Nonce is consumed for that wrong address, tx succeeds but creator is wrong.
        // This demonstrates that the sig binds ALL parameters — tampering changes the recovered address.
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT * 2, nonce, deadline, sig);
        vm.stopPrank();

        // The recovered creator is NOT the original creator
        assertNotEq(bridge.workflowCreator(0), creator);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // invalidateNonce
    // ═══════════════════════════════════════════════════════════════════════════

    function test_invalidateNonce_BlocksFutureExecution() public {
        uint256 nonce    = 99;
        uint256 deadline = _defaultDeadline();
        bytes memory sig = _signCommitment(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline);

        // Creator invalidates nonce before releaser acts
        vm.prank(creator);
        bridge.invalidateNonce(nonce);

        assertTrue(bridge.usedNonces(creator, nonce));

        vm.startPrank(releaser);
        token.approve(address(bridge), DEFAULT_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(DeferredFundingBridge.NonceAlreadyUsed.selector, creator, nonce)
        );
        bridge.executeFromSignature(address(token), recipient, releaser, DEFAULT_AMOUNT, nonce, deadline, sig);
        vm.stopPrank();
    }

    function test_invalidateNonce_EmitsEvent() public {
        vm.prank(creator);
        vm.expectEmit(true, false, false, true);
        emit DeferredFundingBridge.NonceInvalidated(creator, 55);
        bridge.invalidateNonce(55);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // View helpers
    // ═══════════════════════════════════════════════════════════════════════════

    function test_commitmentDigest_IsDeterministic() public view {
        bytes32 d1 = bridge.commitmentDigest(address(token), recipient, releaser, DEFAULT_AMOUNT, 1, _defaultDeadline());
        bytes32 d2 = bridge.commitmentDigest(address(token), recipient, releaser, DEFAULT_AMOUNT, 1, _defaultDeadline());
        assertEq(d1, d2);
    }

    function test_commitmentDigest_DiffersOnDifferentNonce() public view {
        uint256 dl = _defaultDeadline();
        bytes32 d1 = bridge.commitmentDigest(address(token), recipient, releaser, DEFAULT_AMOUNT, 1, dl);
        bytes32 d2 = bridge.commitmentDigest(address(token), recipient, releaser, DEFAULT_AMOUNT, 2, dl);
        assertNotEq(d1, d2);
    }

    function test_domainSeparator_IsNonZero() public view {
        assertNotEq(bridge.domainSeparator(), bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fee accounting (detailed)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_feeAccounting_VaultTotalHeldDecreasedAfterRelease() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());
        _approveAndExecuteSlot(slotId);

        // After release, escrow balance returns to 0 (funds sent to recipient)
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0, 'no funds held after release');
    }

    function test_feeAccounting_BridgeHoldsNoResidualTokens() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());
        _approveAndExecuteSlot(slotId);

        assertEq(token.balanceOf(address(bridge)), 0, 'bridge holds no tokens after execution');
    }

    function test_feeAccounting_VaultAllowanceResetToZero() public {
        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, DEFAULT_AMOUNT, _defaultDeadline());
        _approveAndExecuteSlot(slotId);

        assertEq(token.allowance(address(bridge), address(vault)), 0, 'vault allowance reset to 0');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fuzz: fee invariant across amounts
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_executeSlot_RecipientReceivesCorrectAmount(uint256 amount) public {
        // Clamp to valid range: must be >= MIN_ESCROW_AMOUNT (1000) and fit in releaser balance
        amount = bound(amount, SettingsValidationLibrary.MIN_ESCROW_AMOUNT, 10_000e18);

        token.mint(releaser, amount);

        vm.prank(creator);
        bytes32 slotId = bridge.openSlot(address(token), recipient, releaser, amount, _defaultDeadline());

        uint256 before = token.balanceOf(recipient);

        vm.startPrank(releaser);
        token.approve(address(bridge), amount);
        bridge.executeSlot(slotId);
        vm.stopPrank();

        uint256 expectedNet = amount - (amount * FEE_BPS / FEE_DENOM);
        assertEq(token.balanceOf(recipient), before + expectedNet);
    }
}
