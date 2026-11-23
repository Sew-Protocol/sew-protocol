// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import "forge-std/Test.sol";
import "../../../packages/sew-core/contracts/core/BaseEscrow.sol";
import "../../../contracts/core/EscrowVault.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../packages/sew-core/contracts/modules/DefaultResolutionModule.sol";
import "../../../packages/sew-core/contracts/types/EscrowTypes.sol";
import "../../../packages/sew-core/contracts/types/YieldPresets.sol";
import "../../../packages/sew-core/contracts/core/EscrowCreationPolicy.sol";
import "../../../packages/sew-core/contracts/core/BondCollector.sol";
import "../../../packages/sew-core/contracts/core/ModuleSnapshotRegistry.sol";
import "../../../packages/sew-core/contracts/libraries/SettingsValidationLibrary.sol";
import "../../../packages/sew-core/contracts/interfaces/IYieldModule.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PartialPrincipalRecoveryModule is IYieldModule {
    mapping(address => mapping(uint256 => uint256)) private _principal;

    function initializeYield(uint256 id, address token, uint256 amount, YieldPreset)
        external returns (uint256 accepted)
    {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount));
        _principal[msg.sender][id] = amount;
        return amount;
    }

    function unwindToEscrow(uint256 id, address token, uint256 expected)
        external returns (uint256 principalOut, uint256 yieldOut)
    {
        require(_principal[msg.sender][id] == expected);
        delete _principal[msg.sender][id];
        principalOut = expected * 80 / 100;
        require(IERC20(token).transfer(msg.sender, principalOut));
    }

    function emergencyUnwind(uint256, address, uint256) external pure returns (uint256) {
        revert('recovery unavailable');
    }

    function previewPosition(uint256 id, address escrow)
        external view returns (uint256 principal, uint256 currentValue, bool isActive)
    {
        principal = _principal[escrow][id];
        currentValue = principal;
        isActive = principal != 0;
    }

    function canHandle(address, YieldPreset, uint256) external pure returns (bool, bytes32) {
        return (true, bytes32(0));
    }

    function getModuleInfo() external pure returns (string memory, string memory, bytes32) {
        return ('PartialPrincipalRecoveryModule', '1.0.0', keccak256('partial-principal-test'));
    }
}

/**
 * @title MutualSplitTest
 * @notice Tests for proposeSplit / acceptSplit / cancelSplit mutual settlement.
 *
 * Key invariants verified:
 *  - buyerAmount + sellerAmount == amountAfterFee on propose and accept
 *  - Only counterparty can accept
 *  - Blocked when pendingSettlement exists
 *  - Expiry enforced on accept
 *  - DISPUTED state: DRM dispute closed, RESOLVED state set
 *  - PENDING state: no dispute to close, RESOLVED state set
 *  - Both parties can claim their claimable balances after settlement
 *  - No automatic token transfer during settlement
 */
contract MutualSplitTest is Test {
    EscrowVault public vault;
    ERC20Mock public token;
    DefaultResolutionModule public resolutionModule;
    EscrowCreationPolicy public creationPolicy;
    BondCollector public bondCollector;
    ModuleSnapshotRegistry public moduleManagement;

    address public owner;
    address public timelock;
    address public guardian;
    address public feeAddress = address(0xFEE);
    address public resolver = address(0x1234);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public unauthorized = address(0x9999);

    uint256 constant ESCROW_FEE_BPS = 0; // simplify: no fee
    uint256 constant AMOUNT = 1000e18;

    function setUp() public {
        owner = address(this);
        timelock = address(0x1);
        guardian = address(0x2);

        token = new ERC20Mock("Test", "TEST", owner, 100000e18);
        moduleManagement = new ModuleSnapshotRegistry(owner);
        creationPolicy = new EscrowCreationPolicy(owner);
        bondCollector = new BondCollector(owner);
        resolutionModule = new DefaultResolutionModule(owner, resolver);

        vault = new EscrowVault(ESCROW_FEE_BPS,feeAddress,address(moduleManagement));


        vault.grantRole(vault.ROLE_TIMELOCK(), timelock);
        vault.grantRole(vault.ROLE_GUARDIAN(), guardian);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), owner);

        vault.setCreationPolicy(address(creationPolicy));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));

        resolutionModule.grantRole(resolutionModule.ROLE_TIMELOCK(), owner);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────────

    function _createEscrow() internal returns (uint256 wid) {
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(vault), AMOUNT);
        wid = vault.createEscrow(address(token), seller, AMOUNT, SettingsValidationLibrary.getDefaultSettings());
        vm.stopPrank();
    }

    function _createDisputedEscrow() internal returns (uint256 wid) {
        wid = _createEscrow();
        vm.prank(buyer);
        vault.raiseDispute(wid);
    }

    // ─── proposeSplit ────────────────────────────────────────────────────────────

    function test_proposeSplit_BuyerProposesFromPendingState() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);

        (address proposer, uint256 ba, uint256 sa, uint64 exp, bool active) = vault.splitProposals(wid);
        assertEq(proposer, buyer);
        assertEq(ba, 600e18);
        assertEq(sa, 400e18);
        assertTrue(active);
        assertGt(exp, block.timestamp);
    }

    function test_proposeSplit_SellerProposesFromPendingState() public {
        uint256 wid = _createEscrow();

        vm.prank(seller);
        vault.proposeSplit(wid, 300e18, 700e18, 0);

        (, , , , bool active) = vault.splitProposals(wid);
        assertTrue(active);
    }

    function test_proposeSplit_BuyerProposesFromDisputedState() public {
        uint256 wid = _createDisputedEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 500e18, 500e18, 0);

        (, , , , bool active) = vault.splitProposals(wid);
        assertTrue(active);
    }

    function test_proposeSplit_NewProposalReplacesOld() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);

        // Seller counter-proposes — replaces buyer's proposal
        vm.prank(seller);
        vault.proposeSplit(wid, 200e18, 800e18, 0);

        (, uint256 ba, uint256 sa, , bool active) = vault.splitProposals(wid);
        assertEq(ba, 200e18);
        assertEq(sa, 800e18);
        assertTrue(active);
    }

    function test_proposeSplit_RevertsIfNotParticipant() public {
        uint256 wid = _createEscrow();

        vm.prank(unauthorized);
        vm.expectRevert();
        vault.proposeSplit(wid, 500e18, 500e18, 0);
    }

    function test_proposeSplit_RevertsIfAmountsMismatch() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vm.expectRevert();
        vault.proposeSplit(wid, 600e18, 600e18, 0); // 1200 != 1000
    }

    function test_proposeSplit_RevertsIfFinalizedState() public {
        uint256 wid = _createEscrow();

        // Finalize via mutual split (→ RESOLVED)
        vm.prank(buyer);
        vault.proposeSplit(wid, 500e18, 500e18, 0);
        vm.prank(seller);
        vault.acceptSplit(wid);

        // Second proposeSplit on a RESOLVED escrow must fail
        vm.prank(buyer);
        vm.expectRevert();
        vault.proposeSplit(wid, 500e18, 500e18, 0);
    }

    function test_proposeSplit_RevertsIfPendingSettlementExists() public {
        uint256 wid = _createDisputedEscrow();

        // Resolver submits ruling → creates pendingSettlement
        vm.prank(resolver);
        vault.releaseAsDisputeResolver(wid, bytes32("ruling-hash"));

        // Now pendingSettlement exists → proposeSplit must be blocked
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SplitProposalBlocked.selector, wid));
        vault.proposeSplit(wid, 500e18, 500e18, 0);
    }

    function test_proposeSplit_CustomExpiry() public {
        uint256 wid = _createEscrow();
        uint64 customExpiry = uint64(block.timestamp + 1 days);

        vm.prank(buyer);
        vault.proposeSplit(wid, 700e18, 300e18, customExpiry);

        (, , , uint64 exp, ) = vault.splitProposals(wid);
        assertEq(exp, customExpiry);
    }

    function test_proposeSplit_RevertsIfExpiryInPast() public {
        uint256 wid = _createEscrow();

        // Warp so block.timestamp > 1 and block.timestamp - 1 is a real past timestamp
        vm.warp(block.timestamp + 1 hours);

        vm.prank(buyer);
        vm.expectRevert();
        vault.proposeSplit(wid, 500e18, 500e18, uint64(block.timestamp - 1));
    }

    // ─── cancelSplit ─────────────────────────────────────────────────────────────

    function test_cancelSplit_ProposerCanCancel() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);

        vm.prank(buyer);
        vault.cancelSplit(wid);

        (, , , , bool active) = vault.splitProposals(wid);
        assertFalse(active);
    }

    function test_cancelSplit_GuardianCanCancel() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);

        vm.prank(guardian);
        vault.cancelSplit(wid);

        (, , , , bool active) = vault.splitProposals(wid);
        assertFalse(active);
    }

    function test_cancelSplit_NonProposerNonGuardianReverts() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);

        vm.prank(unauthorized);
        vm.expectRevert();
        vault.cancelSplit(wid);
    }

    function test_cancelSplit_RevertsIfNoProposal() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SplitNotFound.selector, wid));
        vault.cancelSplit(wid);
    }

    // ─── acceptSplit ─────────────────────────────────────────────────────────────

    function test_acceptSplit_HappyPath_PendingState() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);

        uint256 buyerBalBefore = token.balanceOf(buyer);
        uint256 sellerBalBefore = token.balanceOf(seller);

        vm.prank(seller);
        vault.acceptSplit(wid);

        // Escrow should be RESOLVED
        (, , , , , , , EscrowState state, , ) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.RESOLVED));

        // Proposal deleted
        (, , , , bool active) = vault.splitProposals(wid);
        assertFalse(active);

        // Claimable balances credited — no automatic transfer
        assertEq(token.balanceOf(buyer), buyerBalBefore);
        assertEq(token.balanceOf(seller), sellerBalBefore);
        assertEq(vault.claimableBalances(wid, buyer), 600e18);
        assertEq(vault.claimableBalances(wid, seller), 400e18);
    }

    function test_acceptSplit_allocates_only_recovered_principal_after_yield_loss() public {
        PartialPrincipalRecoveryModule partialModule = new PartialPrincipalRecoveryModule();
        moduleManagement.registerEscrowContract(address(vault));
        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(partialModule));
        vm.warp(block.timestamp + 8 days);
        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.ENABLED;
        token.mint(buyer, AMOUNT);
        vm.startPrank(buyer);
        token.approve(address(vault), AMOUNT);
        uint256 wid = vault.createEscrow(address(token), seller, AMOUNT, settings);
        vm.stopPrank();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);
        vm.prank(seller);
        vault.acceptSplit(wid);

        uint256 recovered = AMOUNT * 80 / 100;
        uint256 buyerRecovery = recovered * 60 / 100;
        uint256 sellerRecovery = recovered - buyerRecovery;
        assertEq(vault.claimableBalances(wid, buyer), buyerRecovery);
        assertEq(vault.claimableBalances(wid, seller), sellerRecovery);
        assertEq(vault.totalClaimableAssets(address(token)), recovered);
        assertEq(token.balanceOf(address(vault)), recovered);

        vm.prank(buyer);
        vault.withdrawEscrow(wid);
        vm.prank(seller);
        vault.withdrawEscrow(wid);
        assertEq(token.balanceOf(buyer) + token.balanceOf(seller), recovered);
    }

    function test_acceptSplit_HappyPath_DisputedState() public {
        uint256 wid = _createDisputedEscrow();

        vm.prank(seller);
        vault.proposeSplit(wid, 400e18, 600e18, 0);

        vm.prank(buyer);
        vault.acceptSplit(wid);

        (, , , , , , , EscrowState state, , ) = vault.escrowTransfers(wid);
        assertEq(uint8(state), uint8(EscrowState.RESOLVED));

        assertEq(vault.claimableBalances(wid, buyer), 400e18);
        assertEq(vault.claimableBalances(wid, seller), 600e18);
    }

    function test_acceptSplit_BothPartiesCanWithdrawAfter() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);

        vm.prank(seller);
        vault.acceptSplit(wid);

        // Buyer withdraws
        vm.prank(buyer);
        vault.withdrawEscrow(wid);
        assertEq(token.balanceOf(buyer), 600e18);

        // Seller withdraws
        vm.prank(seller);
        vault.withdrawEscrow(wid);
        assertEq(token.balanceOf(seller), 400e18);
    }

    function test_acceptSplit_FullRefund_BuyerGetsAll() public {
        uint256 wid = _createEscrow();

        vm.prank(seller);
        vault.proposeSplit(wid, 1000e18, 0, 0);

        vm.prank(buyer);
        vault.acceptSplit(wid);

        assertEq(vault.claimableBalances(wid, buyer), 1000e18);
        assertEq(vault.claimableBalances(wid, seller), 0);
    }

    function test_acceptSplit_FullRelease_SellerGetsAll() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 0, 1000e18, 0);

        vm.prank(seller);
        vault.acceptSplit(wid);

        assertEq(vault.claimableBalances(wid, buyer), 0);
        assertEq(vault.claimableBalances(wid, seller), 1000e18);
    }

    function test_acceptSplit_RevertsIfProposerTriesToAcceptOwn() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NotCounterparty.selector, wid, buyer));
        vault.acceptSplit(wid);
    }

    function test_acceptSplit_RevertsIfNoProposal() public {
        uint256 wid = _createEscrow();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SplitNotFound.selector, wid));
        vault.acceptSplit(wid);
    }

    function test_acceptSplit_RevertsIfExpired() public {
        uint256 wid = _createEscrow();
        uint64 customExpiry = uint64(block.timestamp + 1 hours);

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, customExpiry);

        // Advance time past expiry
        vm.warp(block.timestamp + 2 hours);

        vm.prank(seller);
        vm.expectRevert();
        vault.acceptSplit(wid);
    }

    function test_acceptSplit_RevertsIfPendingSettlementExists() public {
        uint256 wid = _createDisputedEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 500e18, 500e18, 0);

        // Resolver submits ruling → pendingSettlement created
        vm.prank(resolver);
        vault.releaseAsDisputeResolver(wid, bytes32("hash"));

        // acceptSplit must now be blocked
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SplitProposalBlocked.selector, wid));
        vault.acceptSplit(wid);
    }

    function test_acceptSplit_RevertsIfUnauthorized() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 600e18, 400e18, 0);

        vm.prank(unauthorized);
        vm.expectRevert();
        vault.acceptSplit(wid);
    }

    function test_acceptSplit_RevertsIfAlreadyFinalized() public {
        uint256 wid = _createEscrow();

        // Finalize via mutual split
        vm.prank(buyer);
        vault.proposeSplit(wid, 500e18, 500e18, 0);
        vm.prank(seller);
        vault.acceptSplit(wid);

        // A second acceptSplit attempt must fail (no proposal, and state is RESOLVED)
        vm.prank(buyer);
        vm.expectRevert();
        vault.acceptSplit(wid);
    }

    // ─── Conservation invariant ──────────────────────────────────────────────────

    function test_invariant_TotalClaimableEqualsPrincipal() public {
        uint256 wid = _createEscrow();

        vm.prank(buyer);
        vault.proposeSplit(wid, 700e18, 300e18, 0);

        vm.prank(seller);
        vault.acceptSplit(wid);

        uint256 buyerClaim = vault.claimableBalances(wid, buyer);
        uint256 sellerClaim = vault.claimableBalances(wid, seller);
        assertEq(buyerClaim + sellerClaim, AMOUNT, "conservation: claimables must equal principal");
    }
}
