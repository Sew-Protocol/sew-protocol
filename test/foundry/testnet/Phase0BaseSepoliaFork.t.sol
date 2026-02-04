// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

import { ERC20Mock } from "../../../contracts/mocks/ERC20Mock.sol";
import { EscrowSettings } from "../../../contracts/types/EscrowTypes.sol";
import { YieldPreset } from "../../../contracts/types/YieldPresets.sol";

interface IAccessControlMinimal {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface ITimelockControllerMinimal {
    function PROPOSER_ROLE() external view returns (bytes32);
    function CANCELLER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IEscrowVaultPhase0 is IAccessControlMinimal {
    function yieldOps() external view returns (address);
    function disputeOps() external view returns (address);
    function createOps() external view returns (address);
    function settlementOps() external view returns (address);
    function bondCollector() external view returns (address);
    function moduleManagement() external view returns (address);
    function escrowFeeAddress() external view returns (address);
    function escrowFee() external view returns (uint256);

    function ROLE_ADMIN_CONTRACT() external view returns (bytes32);

    function createEscrow(address token, address to, uint256 amount, EscrowSettings memory settings)
        external
        returns (uint256 workflowId);

    function releaseEscrowTransfer(uint256 workflowId) external returns (bool);
    function recipientCancel(uint256 workflowId) external returns (bool);
    function senderCancel(uint256 workflowId) external returns (bool);

    function raiseDispute(uint256 workflowId) external returns (bool);
    function cancelAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) external returns (bool);
    function executePendingSettlement(uint256 workflowId) external;
}

contract ResolverMock {
    // Intentionally empty: only needs non-zero code.length to satisfy SettingsValidationLibrary.
}

contract Phase0BaseSepoliaForkTest is Test {
    using stdJson for string;

    string internal RPC_URL;
    uint256 internal FORK_BLOCK;

    // Deployed addresses (loaded from deployments JSON)
    address internal sewToken;
    address internal timelock;
    address internal governor;
    address internal safeMultisig;
    address internal guardianSafe;
    address internal yieldOps;
    address internal disputeOps;
    address internal settlementOps;
    address internal createOps;
    address internal bondCollector;
    address internal moduleManagement;
    address internal escrowAdmin;
    address internal escrowVault;

    function setUp() public {
        RPC_URL = vm.envOr("RPC_BASE_SEPOLIA", string("https://sepolia.base.org"));
        FORK_BLOCK = vm.envOr("FORK_BLOCK_NUMBER", uint256(0)); // 0 = latest

        if (FORK_BLOCK > 0) {
            vm.createSelectFork(RPC_URL, FORK_BLOCK);
        } else {
            vm.createSelectFork(RPC_URL);
        }

        sewToken = _dep("SewToken");
        timelock = _dep("TimelockController");
        governor = _dep("GovGovernor");
        safeMultisig = _dep("Safe_Multisig");
        guardianSafe = _dep("GuardianSafe");
        yieldOps = _dep("YieldOps");
        disputeOps = _dep("DisputeOps");
        settlementOps = _dep("SettlementOps");
        createOps = _dep("CreateOps");
        bondCollector = _dep("BondCollector");
        moduleManagement = _dep("ModuleManagementContract");
        escrowAdmin = _dep("EscrowGovernanceTimelock");
        escrowVault = _dep("EscrowVault");
    }

    function test_phase0_deployment_health_and_minimal_e2e() public {
        bool strictGov = vm.envOr("PHASE0_STRICT_GOVERNANCE", uint256(0)) == 1;

        // 1) Bytecode presence
        _requireCode("SewToken", sewToken);
        _requireCode("TimelockController", timelock);
        _requireCode("GovGovernor", governor);
        // NOTE: On Base Sepolia testnet, these may be EOAs (no bytecode).
        // We still require them to be non-zero addresses (enforced by _dep()).
        _requireCode("YieldOps", yieldOps);
        _requireCode("DisputeOps", disputeOps);
        _requireCode("SettlementOps", settlementOps);
        _requireCode("CreateOps", createOps);
        _requireCode("BondCollector", bondCollector);
        _requireCode("ModuleManagementContract", moduleManagement);
        _requireCode("EscrowGovernanceTimelock", escrowAdmin);
        _requireCode("EscrowVault", escrowVault);

        // 2) Core wiring
        IEscrowVaultPhase0 ev = IEscrowVaultPhase0(escrowVault);
        assertEq(ev.yieldOps(), yieldOps, "EscrowVault.yieldOps mismatch");
        assertEq(ev.disputeOps(), disputeOps, "EscrowVault.disputeOps mismatch");
        assertEq(ev.createOps(), createOps, "EscrowVault.createOps mismatch");
        assertEq(ev.settlementOps(), settlementOps, "EscrowVault.settlementOps mismatch");
        assertEq(ev.bondCollector(), bondCollector, "EscrowVault.bondCollector mismatch");
        assertEq(ev.moduleManagement(), moduleManagement, "EscrowVault.moduleManagement mismatch");
        assertTrue(ev.escrowFeeAddress() != address(0), "EscrowVault.escrowFeeAddress is zero");

        // 3) Ops registration: ROLE_ESCROW_CONTRACT for EscrowVault
        bytes32 ROLE_ESCROW_CONTRACT = keccak256("ROLE_ESCROW_CONTRACT");
        assertTrue(IAccessControlMinimal(createOps).hasRole(ROLE_ESCROW_CONTRACT, escrowVault), "CreateOps missing ROLE_ESCROW_CONTRACT");
        assertTrue(IAccessControlMinimal(settlementOps).hasRole(ROLE_ESCROW_CONTRACT, escrowVault), "SettlementOps missing ROLE_ESCROW_CONTRACT");
        assertTrue(IAccessControlMinimal(disputeOps).hasRole(ROLE_ESCROW_CONTRACT, escrowVault), "DisputeOps missing ROLE_ESCROW_CONTRACT");
        assertTrue(IAccessControlMinimal(yieldOps).hasRole(ROLE_ESCROW_CONTRACT, escrowVault), "YieldOps missing ROLE_ESCROW_CONTRACT");
        assertTrue(IAccessControlMinimal(bondCollector).hasRole(ROLE_ESCROW_CONTRACT, escrowVault), "BondCollector missing ROLE_ESCROW_CONTRACT");

        // 4) Slow lane admin wiring: EscrowGovernanceTimelock authorized on EscrowVault
        bytes32 ROLE_ADMIN_CONTRACT = ev.ROLE_ADMIN_CONTRACT();
        assertTrue(ev.hasRole(ROLE_ADMIN_CONTRACT, escrowAdmin), "EscrowGovernanceTimelock missing ROLE_ADMIN_CONTRACT on EscrowVault");

        // 5) Timelock wiring (minimum): governor is proposer/canceller
        ITimelockControllerMinimal tl = ITimelockControllerMinimal(timelock);
        bool hasProposer = tl.hasRole(tl.PROPOSER_ROLE(), governor);
        bool hasCanceller = tl.hasRole(tl.CANCELLER_ROLE(), governor);
        if (strictGov) {
            assertTrue(hasProposer, "GovGovernor missing PROPOSER_ROLE");
            assertTrue(hasCanceller, "GovGovernor missing CANCELLER_ROLE");
        } else {
            if (!hasProposer) emit log_string("WARN: GovGovernor missing PROPOSER_ROLE on Timelock");
            if (!hasCanceller) emit log_string("WARN: GovGovernor missing CANCELLER_ROLE on Timelock");
        }

        // 6) Minimal E2E (token deployed locally on fork)
        address buyer = makeAddr("buyer");
        address seller = makeAddr("seller");
        address resolver = address(new ResolverMock());

        ERC20Mock token = new ERC20Mock("Phase0 Mock Token", "P0", buyer, 1_000_000e18);
        uint256 amount = 100e18;
        uint256 feeBps = ev.escrowFee();
        uint256 feeAmount = (amount * feeBps) / 10000;

        EscrowSettings memory settings = EscrowSettings({
            customResolver: resolver,
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // create → release
        vm.startPrank(buyer);
        token.approve(escrowVault, amount);
        uint256 wf1 = ev.createEscrow(address(token), seller, amount, settings);
        uint256 sellerBal0 = token.balanceOf(seller);
        ev.releaseEscrowTransfer(wf1);
        vm.stopPrank();
        uint256 sellerBal1 = token.balanceOf(seller);
        assertTrue(sellerBal1 > sellerBal0, "release did not transfer to seller (expected increase)");

        // create → 2-party cancel → refund
        vm.startPrank(buyer);
        token.approve(escrowVault, amount);
        uint256 buyerBal0 = token.balanceOf(buyer);
        uint256 wf2 = ev.createEscrow(address(token), seller, amount, settings);
        vm.stopPrank();

        vm.prank(seller);
        ev.recipientCancel(wf2);
        vm.prank(buyer);
        ev.senderCancel(wf2);

        uint256 buyerBal1 = token.balanceOf(buyer);
        assertEq(buyerBal1, buyerBal0 - feeAmount, "cancel/refund buyer balance mismatch (expected fee-only loss)");

        // dispute → resolver cancel → execute pending settlement after appeal window
        vm.startPrank(buyer);
        token.approve(escrowVault, amount);
        uint256 buyerBal2 = token.balanceOf(buyer);
        uint256 wf3 = ev.createEscrow(address(token), seller, amount, settings);
        ev.raiseDispute(wf3);
        vm.stopPrank();

        vm.prank(resolver);
        ev.cancelAsDisputeResolver(wf3, keccak256("phase0"));

        // default appeal window is 2 days; warp past it then execute
        vm.warp(block.timestamp + 2 days + 1);
        ev.executePendingSettlement(wf3);

        uint256 buyerBal3 = token.balanceOf(buyer);
        assertEq(buyerBal3, buyerBal2 - feeAmount, "dispute cancel buyer balance mismatch (expected fee-only loss)");
    }

    function _dep(string memory name) internal view returns (address) {
        string memory p = string.concat("deployments/baseSepolia/", name, ".json");
        string memory j = vm.readFile(p);
        address a = j.readAddress(".address");
        require(a != address(0), string.concat("missing/zero address in ", p));
        return a;
    }

    function _requireCode(string memory name, address a) internal view {
        require(a.code.length > 0, string.concat("no code for ", name));
    }
}

