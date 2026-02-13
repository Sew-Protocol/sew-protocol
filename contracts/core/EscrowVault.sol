// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './BaseEscrow.sol';
import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import './ModuleSnapshotRegistry.sol';
import '../libraries/FeeRecordingLibrary.sol';
import '../libraries/BalanceUpdateLibrary.sol';
import '../libraries/FeeWithdrawalLibrary.sol';

contract EscrowVault is BaseEscrow {
    using SafeERC20 for IERC20;


    mapping(address => uint256) public totalFeesPerToken;
    mapping(address => uint256) public totalHeldInEscrowPerToken;

    ModuleSnapshotRegistry public immutable moduleManagement;

    event FeesWithdrawn(address indexed token, uint256 amount);

    constructor(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) {
        address deployer = _msgSender();
        _grantRole(DEFAULT_ADMIN_ROLE, deployer);
        _grantRole(ROLE_TIMELOCK, deployer);
        if (escrowFeeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(escrowFeeBps, MAX_ESCROW_FEE_BPS);
        if (feeAddress == address(0)) revert ZeroAddress(1);
        if (yieldOpsAddress == address(0)) revert ZeroAddress(2);
        if (disputeOpsAddress == address(0)) revert ZeroAddress(3);
        if (moduleManagementAddress == address(0)) revert ZeroAddress(4);
        if (yieldOpsAddress.code.length == 0) revert ZeroAddress(2);
        if (disputeOpsAddress.code.length == 0) revert ZeroAddress(3);
        if (moduleManagementAddress.code.length == 0) revert ZeroAddress(4);
        escrowFee = escrowFeeBps;
        escrowFeeAddress = feeAddress;
        moduleManagement = ModuleSnapshotRegistry(moduleManagementAddress);
        yieldOps = YieldOps(yieldOpsAddress);
        disputeOps = DisputeOps(disputeOpsAddress);
        yieldProtocolFeeBps = DEFAULT_YIELD_PROTOCOL_FEE_BPS;
        appealBondProtocolFeeBps = 0;
        timeoutConfig.defaultAutoReleaseDelay = 0;
        timeoutConfig.defaultAutoCancelDelay = 0;
        timeoutConfig.maxDisputeDuration = 90 days;
        timeoutConfig.appealWindowDuration = 2 days;
    }

    function releaseEscrowTransfer(uint256 workflowId) public nonReentrant {
        _requirePending(workflowId);
        if (escrowTransfers[workflowId].from != _msgSender()) revert NotSender(workflowId, _msgSender(), escrowTransfers[workflowId].from);
        _releaseEscrowTransfer(workflowId);
    }

    function _pullTokens(address token, address from, uint256 amount) internal override {
        IERC20(token).safeTransferFrom(from, address(this), amount);
    }
    function _recordFee(address token, uint256 amount) internal override {
        FeeRecordingLibrary.recordFee(totalFeesPerToken, token, amount);
    }
    function _depositForYield(IYieldModule generationModule, uint256 workflowId, address token, uint256 amount) internal override {
        address m = address(generationModule);
        if (IERC20(token).allowance(address(this), m) < amount) {
            IERC20(token).safeIncreaseAllowance(m, type(uint256).max);
        }
        uint256 b = IERC20(token).balanceOf(address(this));
        uint256 accepted = generationModule.initializeYield(workflowId, token, amount, YieldPreset.OFF);
        if (b - IERC20(token).balanceOf(address(this)) < accepted) revert AccountingDeficit(token, amount);
    }
    function _transferTokens(address token, address to, uint256 amount) internal override {
        IERC20(token).safeTransfer(to, amount);
    }
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
        BalanceUpdateLibrary.updateBalance(totalHeldInEscrowPerToken, token, amount, add);
    }
    function _emitEscrowTransferCancelled(uint256, address, address, uint256) internal pure override {}
    function _emitEscrowTransferReleased(uint256, address, address, uint256) internal pure override {}

    function getAccountingBreakdown(address token) external view returns (
        uint256 principalHeld,
        uint256 feesCollected,
        uint256 contractBalance,
        uint256 yieldInBalance
    ) {
        principalHeld = totalHeldInEscrowPerToken[token];
        feesCollected = totalFeesPerToken[token];
        contractBalance = IERC20(token).balanceOf(address(this));
        unchecked {
            uint256 expected = principalHeld + feesCollected + totalClaimableAssets[token];
            yieldInBalance = contractBalance > expected ? contractBalance - expected : 0;
        }
    }

    bytes32 public constant ROLE_FEE_RECIPIENT = keccak256('ROLE_FEE_RECIPIENT');

    function withdrawFees(address token) external onlyRole(ROLE_FEE_RECIPIENT) nonReentrant {
        uint256 feeAmount = FeeWithdrawalLibrary.withdrawFees(totalFeesPerToken, token, escrowFeeAddress);
        emit FeesWithdrawn(token, feeAmount);
    }

    function _getDefaultReleaseStrategy() internal view returns (IReleaseStrategy) {
        return moduleManagement.getDefaultReleaseStrategy(address(this));
    }

    function _getDefaultYieldGenerationModule(uint256 workflowId) internal view returns (IYieldGenerationModule) {
        return IYieldGenerationModule(moduleManagement.getDefaultYieldGenerationModule(address(this)));
    }

    function _getDefaultYieldDistributionModule(uint256 workflowId) internal view returns (IYieldDistributionModule) {
        return IYieldDistributionModule(moduleManagement.getDefaultYieldDistributionModule(address(this)));
    }

    function _getYieldGenerationModule(uint256 workflowId) internal view override returns (IYieldModule) {
        address moduleAddr = address(moduleManagement.getDefaultYieldGenerationModule(address(this)));
        if (moduleAddr == address(0)) {
            return IYieldModule(address(0));
        }
        return IYieldModule(moduleAddr);
    }

    function _getYieldDistributionModule(uint256 workflowId) internal view override returns (IYieldDistributionModule) {
        return _getDefaultYieldDistributionModule(workflowId);
    }

    function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
        return _getDefaultReleaseStrategy();
    }

    function _emitEscrowTransferCreated(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount
    ) internal override {}

}
