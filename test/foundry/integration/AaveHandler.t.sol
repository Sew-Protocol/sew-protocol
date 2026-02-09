// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {EscrowVault} from "../../../contracts/core/EscrowVault.sol";
import {BaseEscrow} from "../../../contracts/core/BaseEscrow.sol";
import {ERC20Mock} from "../../../contracts/mocks/ERC20Mock.sol";
import {MockAavePool} from "../../../contracts/mocks/MockAavePool.sol";
import {AaveYieldGenerationModule} from "../../../contracts/modules/AaveYieldGenerationModule.sol";
import {DefaultYieldDistributionModule} from "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import {EscrowSettings, YieldPreset, EscrowState} from "../../../contracts/types/EscrowTypes.sol";

contract AaveHandler is CommonBase, StdCheats, StdUtils {
    EscrowVault public vault;
    AaveYieldGenerationModule public aaveModule;
    MockAavePool public aavePool;
    ERC20Mock public token;
    
    address[] public users;
    uint256[] public activeWorkflows;
    uint256 public totalClaimable;
    
    uint256 public constant MAX_USERS = 5;
    uint256 public constant INITIAL_BALANCE = 1000000e18;
    
    constructor(
        EscrowVault _vault,
        AaveYieldGenerationModule _aaveModule,
        MockAavePool _aavePool,
        ERC20Mock _token
    ) {
        vault = _vault;
        aaveModule = _aaveModule;
        aavePool = _aavePool;
        token = _token;
        
        for (uint160 i = 1; i <= MAX_USERS; i++) {
            address user = address(i + 1000);
            users.push(user);
            token.mint(user, INITIAL_BALANCE);
        }
    }
    
    function createEscrow(uint256 userIndex, uint256 amount) public {
        amount = bound(amount, 1e15, 1000e18);
        address user = users[bound(userIndex, 0, users.length - 1)];
        address recipient = users[bound(userIndex + 1, 0, users.length - 1)];
        if (user == recipient) recipient = users[0];
        
        vm.startPrank(user);
        token.approve(address(vault), amount);
        
        uint256 claimableBefore = vault.totalClaimableAssets(address(token));
        uint256 workflowId = vault.createEscrow(
            address(token),
            recipient,
            amount,
            EscrowSettings({
                customResolver: address(0),
                releaseAddress: address(0), // Added default releaseAddress
                yieldPreset: YieldPreset.TO_SENDER,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();
        
        uint256 claimableAfter = vault.totalClaimableAssets(address(token));
        if (claimableAfter > claimableBefore) {
            totalClaimable += (claimableAfter - claimableBefore);
        }
        
        activeWorkflows.push(workflowId);
    }
    
    function releaseEscrow(uint256 workflowIndex) public {
        if (activeWorkflows.length == 0) return;
        uint256 index = bound(workflowIndex, 0, activeWorkflows.length - 1);
        uint256 workflowId = activeWorkflows[index];
        
        (address token_, , address from, , , , , EscrowState state, , ) = vault.escrowTransfers(workflowId);
        if (state != EscrowState.PENDING) return;
        
        uint256 claimableBefore = vault.totalClaimableAssets(token_);
        vm.prank(from);
        vault.releaseEscrowTransfer(workflowId);
        uint256 claimableAfter = vault.totalClaimableAssets(token_);
        
        if (claimableAfter > claimableBefore) {
            totalClaimable += (claimableAfter - claimableBefore);
        }
        
        // Remove from active if no longer pending
        (, , , , , , , EscrowState newState, , ) = vault.escrowTransfers(workflowId);
        if (newState != EscrowState.PENDING) {
            _removeWorkflow(index);
        }
    }

    function withdrawClaimable(uint256 userIndex, uint256 workflowId) public {
        address user = users[bound(userIndex, 0, users.length - 1)];
        uint256 amount = vault.claimableBalances(workflowId, user);
        if (amount == 0) return;
        
        uint256 claimableBefore = vault.totalClaimableAssets(address(token));
        vm.prank(user);
        vault.withdrawEscrow(workflowId);
        uint256 claimableAfter = vault.totalClaimableAssets(address(token));
        
        if (claimableBefore > claimableAfter) {
            totalClaimable -= (claimableBefore - claimableAfter);
        }
    }

    function senderCancel(uint256 workflowIndex) public {
        if (activeWorkflows.length == 0) return;
        uint256 index = bound(workflowIndex, 0, activeWorkflows.length - 1);
        uint256 workflowId = activeWorkflows[index];
        
        (address token_, , address from, , , , , EscrowState state, , ) = vault.escrowTransfers(workflowId);
        if (state != EscrowState.PENDING) return;
        
        uint256 claimableBefore = vault.totalClaimableAssets(token_);
        vm.prank(from);
        vault.senderCancel(workflowId);
        
        uint256 claimableAfter = vault.totalClaimableAssets(token_);
        if (claimableAfter > claimableBefore) {
            totalClaimable += (claimableAfter - claimableBefore);
        }
        
        (, , , , , , , EscrowState newState, , ) = vault.escrowTransfers(workflowId);
        if (newState != EscrowState.PENDING) {
            _removeWorkflow(index);
        }
    }
    
    function recipientCancel(uint256 workflowIndex) public {
        if (activeWorkflows.length == 0) return;
        uint256 index = bound(workflowIndex, 0, activeWorkflows.length - 1);
        uint256 workflowId = activeWorkflows[index];
        
        (address token_, address to, , , , , , EscrowState state, , ) = vault.escrowTransfers(workflowId);
        if (state != EscrowState.PENDING) return;
        
        uint256 claimableBefore = vault.totalClaimableAssets(token_);
        vm.prank(to);
        vault.recipientCancel(workflowId);
        
        uint256 claimableAfter = vault.totalClaimableAssets(token_);
        if (claimableAfter > claimableBefore) {
            totalClaimable += (claimableAfter - claimableBefore);
        }

        (, , , , , , , EscrowState newState, , ) = vault.escrowTransfers(workflowId);
        if (newState != EscrowState.PENDING) {
            _removeWorkflow(index);
        }
    }
    
    function accrueInterest(uint256 blocks) public {
        blocks = bound(blocks, 0, 100);
        aavePool.simulateYield(address(token), blocks);
    }
    
    function warpTime(uint256 seconds_) public {
        seconds_ = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + seconds_);
    }
    
    function _removeWorkflow(uint256 index) internal {
        activeWorkflows[index] = activeWorkflows[activeWorkflows.length - 1];
        activeWorkflows.pop();
    }
}
