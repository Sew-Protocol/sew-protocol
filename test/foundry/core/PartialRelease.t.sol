// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/modules/DefaultReleaseStrategy.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';

contract PartialReleaseTest is Test {
    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant AMOUNT = 1000e18;
    uint256 constant EXPECTED_FEE = AMOUNT * FEE_BPS / 10_000;

    address buyer = address(0xCAFE);
    address seller = address(0xBEEF);
    address feeAddress = address(0xFEE);
    address feePicker = address(0xF1);

    ERC20Mock token;
    EscrowVault vault;
    ModuleSnapshotRegistry moduleManagement;
    DefaultReleaseStrategy releaseStrategy;
    YieldOps yieldOps;
    DisputeOps disputeOps;
    SettlementOps settlementOps;
    CreateOps createOps;
    BondCollector bondCollector;
    DefaultResolutionModule resolutionModule;

    function setUp() public {
        token = new ERC20Mock('Token', 'TKN', address(this), 1_000_000e18);

        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        resolutionModule = new DefaultResolutionModule(address(this), address(0x1234));
        releaseStrategy = new DefaultReleaseStrategy();
        moduleManagement = new ModuleSnapshotRegistry(address(this));

        vault = new EscrowVault(FEE_BPS, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));

        moduleManagement.registerEscrowContract(address(vault));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));
        vault.grantRole(vault.ROLE_FEE_RECIPIENT(), feePicker);
    }

    function _createEscrow(address from, uint256 amount) internal returns (uint256) {
        token.mint(from, amount);
        vm.prank(from);
        token.approve(address(vault), amount);
        vm.prank(from);
        return vault.createEscrow(address(token), seller, amount, _defaultSettings());
    }

    function _defaultSettings() internal pure returns (EscrowSettings memory) {
        return EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
    }

    // ============ Happy Path Tests ============

    function test_partialRelease_happyPath() public {
        uint256 id = _createEscrow(buyer, AMOUNT);

        uint256 partialAmount = AMOUNT / 2;
        uint256 remaining = AMOUNT - EXPECTED_FEE - partialAmount;

        vm.prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit BaseEscrow.EscrowPartiallyReleased(id, address(token), seller, partialAmount, partialAmount, AMOUNT - EXPECTED_FEE);
        vault.partialRelease(id, partialAmount);

        assertEq(vault.claimableBalances(id, seller), partialAmount);
        assertEq(
            vault.totalHeldInEscrowPerToken(address(token)),
            AMOUNT - EXPECTED_FEE - partialAmount,
            "held should decrease by partial amount"
        );
        assertEq(uint256(vault.getEscrowState(id)), uint256(EscrowState.PENDING));
    }

    function test_partialRelease_fullAmountFinalizes() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 amountAfterFee = AMOUNT - EXPECTED_FEE;

        vm.prank(buyer);
        vault.partialRelease(id, amountAfterFee);

        assertEq(uint256(vault.getEscrowState(id)), uint256(EscrowState.RELEASED));
        assertEq(vault.amountReleased(id), amountAfterFee);
        assertEq(vault.claimableBalances(id, seller), amountAfterFee);
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0);
    }

    function test_partialRelease_multipleChunks() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 amountAfterFee = AMOUNT - EXPECTED_FEE;

        vm.startPrank(buyer);
        vault.partialRelease(id, amountAfterFee / 4);
        vault.partialRelease(id, amountAfterFee / 4);
        vault.partialRelease(id, amountAfterFee / 4);
        vault.partialRelease(id, amountAfterFee / 4);
        vm.stopPrank();

        assertEq(uint256(vault.getEscrowState(id)), uint256(EscrowState.RELEASED));
        assertEq(vault.claimableBalances(id, seller), amountAfterFee);
        assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0);
    }

    function test_partialRelease_thenFullRelease() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 amountAfterFee = AMOUNT - EXPECTED_FEE;
        uint256 half = amountAfterFee / 2;

        vm.startPrank(buyer);
        vault.partialRelease(id, half);
        vault.release(id);
        vm.stopPrank();

        assertEq(uint256(vault.getEscrowState(id)), uint256(EscrowState.RELEASED));
        assertEq(vault.claimableBalances(id, seller), amountAfterFee);
    }

    function test_partialRelease_thenCancelRefundsRemaining() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 amountAfterFee = AMOUNT - EXPECTED_FEE;
        uint256 partialAmount = amountAfterFee / 3;
        uint256 remaining = amountAfterFee - partialAmount;

        token.mint(seller, 1e18);
        vm.prank(seller);
        token.approve(address(vault), 1e18);

        vm.prank(buyer);
        vault.partialRelease(id, partialAmount);

        vm.prank(seller);
        vault.recipientCancel(id);
        vm.prank(buyer);
        vault.senderCancel(id);

        assertEq(uint256(vault.getEscrowState(id)), uint256(EscrowState.REFUNDED));
        assertEq(vault.claimableBalances(id, seller), partialAmount);
        assertEq(vault.claimableBalances(id, buyer), remaining);
    }

    // ============ Withdrawal Tests ============

    function test_partialRelease_withdrawWhilePending() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 partialAmount = 100e18;

        vm.prank(buyer);
        vault.partialRelease(id, partialAmount);

        uint256 sellerBefore = token.balanceOf(seller);
        vm.prank(seller);
        uint256 withdrawn = vault.withdrawEscrow(id);
        assertEq(withdrawn, partialAmount);
        assertEq(token.balanceOf(seller), sellerBefore + partialAmount);
        assertEq(vault.claimableBalances(id, seller), 0);
        assertEq(uint256(vault.getEscrowState(id)), uint256(EscrowState.PENDING));
    }

    // ============ Revert Tests ============

    function test_partialRelease_revert_nonSender() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSignature("NotSender(uint256,address,address)", id, seller, buyer)
        );
        vault.partialRelease(id, 100e18);
    }

    function test_partialRelease_revert_zeroAmount() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(AmountZero.selector);
        vault.partialRelease(id, 0);
    }

    function test_partialRelease_revert_exceedsRemaining() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 amountAfterFee = AMOUNT - EXPECTED_FEE;
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(AmountExceedsBalance.selector, amountAfterFee + 1, amountAfterFee)
        );
        vault.partialRelease(id, amountAfterFee + 1);
    }

    function test_partialRelease_revert_exceedsRemainingAfterPrevious() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 amountAfterFee = AMOUNT - EXPECTED_FEE;

        vm.startPrank(buyer);
        vault.partialRelease(id, amountAfterFee / 2);

        vm.expectRevert(
            abi.encodeWithSelector(AmountExceedsBalance.selector, amountAfterFee / 2 + 1, amountAfterFee / 2)
        );
        vault.partialRelease(id, amountAfterFee / 2 + 1);
        vm.stopPrank();
    }

    function test_partialRelease_revert_releasedEscrow() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        vm.prank(buyer);
        vault.release(id);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSignature("TransferNotPending(uint256,uint8)", id, EscrowState.RELEASED)
        );
        vault.partialRelease(id, 100e18);
    }

    function test_partialRelease_revert_cancelledEscrow() public {
        uint256 id = _createEscrow(buyer, AMOUNT);

        token.mint(seller, 1e18);
        vm.prank(seller);
        token.approve(address(vault), 1e18);

        vm.prank(seller);
        vault.recipientCancel(id);
        vm.prank(buyer);
        vault.senderCancel(id);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSignature("TransferNotPending(uint256,uint8)", id, EscrowState.REFUNDED)
        );
        vault.partialRelease(id, 100e18);
    }

    // ============ Accounting Tests ============

    function test_partialRelease_accounting() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 amountAfterFee = AMOUNT - EXPECTED_FEE;

        (uint256 heldBefore, uint256 fees, uint256 balance, uint256 yield_) = vault.getAccountingBreakdown(address(token));

        vm.prank(buyer);
        vault.partialRelease(id, amountAfterFee / 2);

        (uint256 heldAfter,,,) = vault.getAccountingBreakdown(address(token));
        assertEq(heldBefore - heldAfter, amountAfterFee / 2);

        uint256 claimable = vault.claimableBalances(id, seller);
        assertEq(claimable, amountAfterFee / 2);
    }

    // ============ Event Tests ============

    function test_partialRelease_emitsEvents() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 amountAfterFee = AMOUNT - EXPECTED_FEE;
        uint256 half = amountAfterFee / 2;

        vm.prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit BaseEscrow.EscrowPartiallyReleased(id, address(token), seller, half, half, amountAfterFee);
        vault.partialRelease(id, half);
    }

    function test_partialRelease_emitsStateChangeOnFullRelease() public {
        uint256 id = _createEscrow(buyer, AMOUNT);
        uint256 amountAfterFee = AMOUNT - EXPECTED_FEE;

        vm.prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit BaseEscrow.EscrowStateChanged(id, EscrowState.PENDING, EscrowState.RELEASED);
        vault.partialRelease(id, amountAfterFee);
    }

    // ============ Release with releaseAddress permission ============

    function test_partialRelease_viaReleaseAddress() public {
        address releaseAddr = address(0xDEC);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: releaseAddr,
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        token.mint(buyer, AMOUNT);
        vm.prank(buyer);
        token.approve(address(vault), AMOUNT);
        vm.prank(buyer);
        uint256 id = vault.createEscrow(address(token), seller, AMOUNT, settings);

        vm.prank(releaseAddr);
        vault.partialRelease(id, 100e18);

        assertEq(vault.claimableBalances(id, seller), 100e18);
    }
}
