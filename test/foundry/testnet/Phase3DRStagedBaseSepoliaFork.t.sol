// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

import { ERC20Mock } from "../../../contracts/mocks/ERC20Mock.sol";
import { EscrowSettings, EscrowState } from "../../../contracts/types/EscrowTypes.sol";
import { YieldPreset } from "../../../contracts/types/YieldPresets.sol";

import { DecentralizedResolutionModule } from "../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol";
import { ResolverIncentiveModuleV2 } from "../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol";
import { PaymentCalculationLibraryV1 } from "../../../contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol";
import { StakingModuleNoOp } from "../../../contracts/decentralized-resolution-module/StakingModuleNoOp.sol";
import { SlashingModuleNoOp } from "../../../contracts/decentralized-resolution-module/SlashingModuleNoOp.sol";

interface IEscrowVaultPhase3 {
    function escrowFee() external view returns (uint256);
    function disputeResolutionModule() external view returns (address);
    function setResolutionModule(address module) external;

    function escrowTransfers(uint256 workflowId)
        external
        view
        returns (
            address token,
            address to,
            address from,
            address disputeResolver,
            uint256 amountAfterFee,
            uint64 autoReleaseTime,
            uint64 autoCancelTime,
            EscrowState escrowState,
            uint8 senderStatus,
            uint8 recipientStatus
        );

    function createEscrow(address token, address to, uint256 amount, EscrowSettings memory settings)
        external
        returns (uint256 workflowId);

    function raiseDispute(uint256 workflowId) external returns (bool);
    function releaseAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) external returns (bool);
    function cancelAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) external returns (bool);
    function escalateDispute(uint256 workflowId) external payable returns (bool, address, uint8);
    function executePendingSettlement(uint256 workflowId) external;
}

contract Phase3DRStagedBaseSepoliaForkTest is Test {
    using stdJson for string;

    // roles used by DR modules
    bytes32 internal constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    bytes32 internal constant ROLE_GUARDIAN = keccak256("ROLE_GUARDIAN");
    bytes32 internal constant ROLE_RESOLUTION_MODULE = keccak256("ROLE_RESOLUTION_MODULE");

    string internal RPC_URL;
    uint256 internal FORK_BLOCK;

    address internal escrowVaultAddr;
    address internal escrowAdminAddr;
    address internal timelockAddr;

    function setUp() public {
        RPC_URL = vm.envOr("RPC_BASE_SEPOLIA", string("https://sepolia.base.org"));
        FORK_BLOCK = vm.envOr("FORK_BLOCK_NUMBER", uint256(0)); // 0 = latest

        if (FORK_BLOCK > 0) vm.createSelectFork(RPC_URL, FORK_BLOCK);
        else vm.createSelectFork(RPC_URL);

        escrowVaultAddr = _dep("EscrowVault");
        escrowAdminAddr = _dep("EscrowAdminContract");
        timelockAddr = _dep("TimelockController");
    }

    /// DR1: decentralized routing + timeouts, no incentives/bonds/staking required to work.
    function test_phase3_dr1_end_to_end_assignment_resolution_and_timeout_progress() public {
        (DecentralizedResolutionModule drm, address resolverL0, address seniorL1) = _deployAndConfigureDRM(false, false);

        // Set EscrowVault resolution module.
        // NOTE: On the current Base Sepolia deployment, EscrowAdminContract may not grant ROLE_TIMELOCK
        // to TimelockController yet, so we set directly as EscrowAdminContract (it holds ROLE_ADMIN_CONTRACT).
        _setResolutionModuleDirect(address(drm));

        IEscrowVaultPhase3 escrow = IEscrowVaultPhase3(escrowVaultAddr);
        assertEq(escrow.disputeResolutionModule(), address(drm), "EscrowVault disputeResolutionModule not set");

        // Create escrow without customResolver (module selects resolver)
        address buyer = makeAddr("buyer");
        address seller = makeAddr("seller");
        vm.deal(buyer, 10 ether);
        vm.deal(seller, 10 ether);

        ERC20Mock token = new ERC20Mock("DR1 Token", "DR1", buyer, 1_000_000e18);
        uint256 amount = 100e18;

        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        vm.startPrank(buyer);
        token.approve(escrowVaultAddr, amount);
        uint256 wf = escrow.createEscrow(address(token), seller, amount, settings);
        vm.stopPrank();

        (, , , address selectedResolver, uint256 amountAfterFee, , , , , ) = escrow.escrowTransfers(wf);
        assertEq(selectedResolver, resolverL0, "DR1 resolver assignment mismatch");

        // Raise dispute; module initializes dispute metadata
        vm.prank(buyer);
        escrow.raiseDispute(wf);

        // Resolve (cancel) as assigned resolver
        vm.prank(resolverL0);
        escrow.cancelAsDisputeResolver(wf, keccak256("dr1"));

        // Wait out appeal window (2 days) then execute pending settlement
        vm.warp(block.timestamp + 2 days + 1);
        uint256 buyerBal0 = token.balanceOf(buyer);
        escrow.executePendingSettlement(wf);
        uint256 buyerBal1 = token.balanceOf(buyer);

        // Buyer receives amountAfterFee (escrow fee may be non-zero)
        assertEq(buyerBal1 - buyerBal0, amountAfterFee, "DR1 refund amount mismatch");

        // Timeout progress: new dispute, warp past resolve deadline, anyone can force progress.
        vm.startPrank(buyer);
        token.approve(escrowVaultAddr, amount);
        uint256 wf2 = escrow.createEscrow(address(token), seller, amount, settings);
        escrow.raiseDispute(wf2);
        vm.stopPrank();

        // Warp past L0 resolve deadline (24h) and forceProgress; should not revert.
        vm.warp(block.timestamp + 24 hours + 1);
        // anyone can call forceProgress
        drm.forceProgress(wf2);

        // If a senior exists, escalation can occur; at minimum, forceProgress should not brick.
        // We sanity-check the current resolver is either L0 resolver or L1 senior or status Final.
        (address cur, uint8 round) = drm.getDisputeResolver(wf2, "");
        assertTrue(cur == resolverL0 || cur == seniorL1 || cur == address(0), "unexpected resolver after forceProgress");
        round; // silence
    }

    /// DR2: appeal bonds. We run L0 decision then sender appeals (bond), L1 flips decision; bond refunded.
    function test_phase3_dr2_appeal_bond_refund_on_flip() public {
        // Deploy DRM + incentive module V2 (bonds enabled) without v3 staking/slashing
        PaymentCalculationLibraryV1 lib = new PaymentCalculationLibraryV1();
        ResolverIncentiveModuleV2 incentives = new ResolverIncentiveModuleV2(address(this), address(lib));
        incentives.grantRole(ROLE_TIMELOCK, address(this));

        (DecentralizedResolutionModule drm, address resolverL0, address seniorL1) = _deployAndConfigureDRM(true, false);

        // Wire incentive module into DRM and register escrow in incentives
        drm.setIncentiveModule(address(incentives));
        // DRM itself calls incentive hooks (onResolverAssigned/onDecisionSubmitted), while EscrowVault
        // calls onDisputeOpened + bond lifecycle functions. Register both.
        incentives.registerEscrowContract(address(drm));
        incentives.registerEscrowContract(escrowVaultAddr);

        // Allow DRM to call incentives (escrow does, but incentives uses msg.sender == escrow contract)
        // No further wiring needed here.

        _setResolutionModuleDirect(address(drm));

        IEscrowVaultPhase3 escrow = IEscrowVaultPhase3(escrowVaultAddr);

        address buyer = makeAddr("buyer");
        address seller = makeAddr("seller");
        vm.deal(buyer, 100 ether);
        vm.deal(seller, 100 ether);

        ERC20Mock token = new ERC20Mock("DR2 Token", "DR2", buyer, 1_000_000e18);
        uint256 amount = 100e18;
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create + dispute
        vm.startPrank(buyer);
        // Approve enough for the escrow principal + a later ERC20 appeal bond pull.
        token.approve(escrowVaultAddr, type(uint256).max);
        uint256 wf = escrow.createEscrow(address(token), seller, amount, settings);
        escrow.raiseDispute(wf);
        vm.stopPrank();

        // L0 resolver decides RELEASE (seller wins)
        vm.prank(resolverL0);
        escrow.releaseAsDisputeResolver(wf, keccak256("l0-release"));

        // Sender (buyer) appeals to L1 (must pay bond). Get required bond from module.
        (, , , , uint256 amountAfterFee, , , , , ) = escrow.escrowTransfers(wf);
        bytes memory escrowData = abi.encode(address(token), buyer, seller, amountAfterFee);
        (uint256 bondAmount, address bondToken) = drm.getRequiredAppealBond(wf, 0, escrowData);
        // DRM enforces bond token == escrow token (see getRequiredAppealBond).
        assertEq(bondToken, address(token), "expected bond token == escrow token");
        assertTrue(bondAmount > 0, "expected non-zero bond");

        // Escalate during appeal window. Must be done before the pending settlement executes.
        vm.prank(buyer);
        escrow.escalateDispute(wf);

        // L1 resolver (senior) flips decision to CANCEL (buyer wins)
        vm.prank(seniorL1);
        escrow.cancelAsDisputeResolver(wf, keccak256("l1-cancel"));

        // Wait out L1 appeal window (3 days), execute pending settlement (refund buyer)
        vm.warp(block.timestamp + 3 days + 1);
        uint256 buyerBal0 = token.balanceOf(buyer);
        escrow.executePendingSettlement(wf);
        uint256 buyerBal1 = token.balanceOf(buyer);
        // executePendingSettlement finalizes the dispute, which refunds the appeal bond (via incentive module)
        // and then executes the escrow refund. Net increase includes both.
        assertEq(buyerBal1 - buyerBal0, amountAfterFee + bondAmount, "DR2 refund mismatch");

        // Bond should be refunded (outcome flipped) by incentive module during finalizeDispute.
        // ResolverIncentiveModuleV2 tracks totals.
        assertTrue(incentives.totalBondsRefunded() >= bondAmount, "expected bond refund accounting");
    }

    /// DR3: enable staking+slashing no-op modules and ensure timeout path triggers slashing hook without reverting.
    function test_phase3_dr3_hooks_staking_and_slashing_noop() public {
        (DecentralizedResolutionModule drm, address resolverL0, ) = _deployAndConfigureDRM(false, true);

        _setResolutionModuleDirect(address(drm));

        IEscrowVaultPhase3 escrow = IEscrowVaultPhase3(escrowVaultAddr);

        address buyer = makeAddr("buyer");
        address seller = makeAddr("seller");
        vm.deal(buyer, 10 ether);

        ERC20Mock token = new ERC20Mock("DR3 Token", "DR3", buyer, 1_000_000e18);
        uint256 amount = 100e18;
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create + dispute
        vm.startPrank(buyer);
        token.approve(escrowVaultAddr, amount);
        uint256 wf = escrow.createEscrow(address(token), seller, amount, settings);
        escrow.raiseDispute(wf);
        vm.stopPrank();

        // Warp past resolve deadline and forceProgress: should call slashing hook (no-op) and not revert.
        vm.warp(block.timestamp + 24 hours + 1);
        drm.forceProgress(wf);

        // Sanity: resolver still a valid address and v3 active flags are true.
        (bool stakingActive, bool slashingActive) = drm.isV3Active();
        assertTrue(stakingActive && slashingActive, "expected v3 modules active");
        (address cur, ) = drm.getDisputeResolver(wf, "");
        assertTrue(cur == resolverL0 || cur == address(0), "unexpected resolver after v3 forceProgress");
    }

    // ======== helpers ========

    function _deployAndConfigureDRM(bool withIncentives, bool withV3Modules)
        internal
        returns (DecentralizedResolutionModule drm, address resolverL0, address seniorL1)
    {
        // Deploy DRM
        drm = new DecentralizedResolutionModule(address(this));
        drm.grantRole(ROLE_TIMELOCK, address(this));
        drm.grantRole(ROLE_GUARDIAN, address(this));

        // Appoint one senior resolver (L1) and one resolver (L0)
        seniorL1 = makeAddr("seniorL1");
        resolverL0 = makeAddr("resolverL0");

        drm.appointSeniorResolver(seniorL1, "senior", "L1 senior");
        // Senior can appoint resolvers
        vm.prank(seniorL1);
        drm.appointResolver(resolverL0, "resolver", "L0 resolver");

        // Ensure active + accepting
        drm.setResolverCapacity(resolverL0, 0, true);
        drm.setResolverCapacity(seniorL1, 0, true);

        // Register EscrowVault as allowed caller for initializeDispute/recordResolution/finalize
        drm.registerEscrowContract(escrowVaultAddr);

        // Optional: v3 modules (no-op) to validate hooks
        if (withV3Modules) {
            StakingModuleNoOp staking = new StakingModuleNoOp(address(this));
            SlashingModuleNoOp slashing = new SlashingModuleNoOp(address(this));
            staking.grantRole(ROLE_RESOLUTION_MODULE, address(drm));
            slashing.grantRole(ROLE_RESOLUTION_MODULE, address(drm));

            // Slow-lane queue/activate requires SLOW_DELAY (7 days)
            drm.queueStakingModule(address(staking));
            drm.queueSlashingModule(address(slashing));
            vm.warp(block.timestamp + 7 days + 1);
            drm.activateStakingModule();
            drm.activateSlashingModule();
        }

        // NOTE: withIncentives is wired by the caller (DR2) because it needs the incentive module instance.
        withIncentives;
    }

    function _setResolutionModuleDirect(address module) internal {
        IEscrowVaultPhase3 escrow = IEscrowVaultPhase3(escrowVaultAddr);
        vm.prank(escrowAdminAddr);
        escrow.setResolutionModule(module);
        assertEq(escrow.disputeResolutionModule(), module, "setResolutionModule failed");
    }

    function _dep(string memory name) internal view returns (address) {
        string memory p = string.concat("deployments/baseSepolia/", name, ".json");
        string memory j = vm.readFile(p);
        address a = j.readAddress(".address");
        require(a != address(0), string.concat("missing address for ", name));
        return a;
    }
}

