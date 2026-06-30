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
import '../libraries/BalanceUpdateLibrary.sol';
import '../libraries/FeeRecordingLibrary.sol';
import '../libraries/EscrowVaultAccountingLibrary.sol';
import '../libraries/EscrowVaultModuleLibrary.sol';
import '../libraries/FeeWithdrawalLibrary.sol';
import '../libraries/EscrowEncodingLibrary.sol';
import '../libraries/StateManagementLibrary.sol';

contract EscrowVault is BaseEscrow {
    using SafeERC20 for IERC20;


    mapping(address => uint256) public totalFeesPerToken;
    mapping(address => uint256) public totalHeldInEscrowPerToken;

    error PartialReleaseNotAllowedWithYield();

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
        
        // Store v2.5 yield tracking data
        v25YieldModules[workflowId] = m;
        v25YieldPrincipals[workflowId] = accepted;
    }
    function _transferTokens(address token, address to, uint256 amount) internal override {
        IERC20(token).safeTransfer(to, amount);
    }
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
        BalanceUpdateLibrary.updateBalance(totalHeldInEscrowPerToken, token, amount, add);
    }

    function getAccountingBreakdown(address token) external view returns (
        uint256 principalHeld,
        uint256 feesCollected,
        uint256 contractBalance,
        uint256 yieldInBalance
    ) {
        return EscrowVaultAccountingLibrary.getAccountingBreakdown(
            totalHeldInEscrowPerToken, 
            totalFeesPerToken, 
            totalClaimableAssets, 
            address(this), 
            token
        );
    }

    bytes32 public constant ROLE_FEE_RECIPIENT = keccak256('ROLE_FEE_RECIPIENT');

    function withdrawFees(address token) external onlyRole(ROLE_FEE_RECIPIENT) nonReentrant {
        uint256 feeAmount = FeeWithdrawalLibrary.withdrawFees(totalFeesPerToken, token, escrowFeeAddress);
        emit FeesWithdrawn(token, feeAmount);
    }

    function _getYieldGenerationModule(uint256 workflowId) internal view override returns (IYieldModule) {
        return EscrowVaultModuleLibrary.getYieldGenerationModule(workflowId, moduleSnapshots, moduleManagement, address(this));
    }

    function _getYieldDistributionModule(uint256 workflowId) internal view override returns (IYieldDistributionModule) {
        return EscrowVaultModuleLibrary.getYieldDistributionModule(
            workflowId,
            moduleSnapshots,
            moduleManagement,
            address(this)
        );
    }

    function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
        return EscrowVaultModuleLibrary.getReleaseStrategy(
            workflowId,
            moduleSnapshots,
            moduleManagement,
            address(this)
        );
    }

    function _getCancellationStrategy(uint256 workflowId) internal view override returns (address) {
        return EscrowVaultModuleLibrary.getCancellationStrategy(workflowId, moduleSnapshots, moduleManagement, address(this));
    }

    function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
        return EscrowVaultModuleLibrary.getResolutionModule(workflowId, moduleSnapshots, moduleManagement, address(this), disputeResolutionModule);
    }

    function partialRelease(uint256 workflowId, uint256 amount) external nonReentrant {
        _validateWorkflowId(workflowId);
        EscrowTransfer storage et = escrowTransfers[workflowId];

        if (et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }

        if (v25YieldModules[workflowId] != address(0)) {
            revert PartialReleaseNotAllowedWithYield();
        }

        if (amount == 0) revert AmountZero();

        uint256 remaining = et.amountAfterFee - amountReleased[workflowId];
        if (amount > remaining) revert AmountExceedsBalance(amount, remaining);

        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(
            et.token, et.from, et.to, et.amountAfterFee, escrowSettings[workflowId].releaseAddress
        );
        IReleaseStrategy strategy = _getReleaseStrategy(workflowId);
        if (address(strategy) == address(0)) {
            revert ReleaseStrategyNotSet(workflowId);
        }
        (bool allowed, uint8 reasonCode) = strategy.canRelease(
            workflowId, address(this), _msgSender(), escrowData
        );
        if (!allowed) {
            if (reasonCode == 1) {
                revert NotSender(workflowId, _msgSender(), et.from);
            } else {
                revert ReleaseNotAllowed(workflowId, reasonCode);
            }
        }

        amountReleased[workflowId] += amount;

        _finalizeClaimableSettlement(workflowId, et.token, amount, et.to);

        if (amountReleased[workflowId] == et.amountAfterFee) {
            _clearPendingSettlementIfExists(workflowId);
            EscrowState oldStatus = StateManagementLibrary.transitionToReleased(et, workflowId);
            emit EscrowStateChanged(workflowId, oldStatus, EscrowState.RELEASED);
            _emitEscrowTransferReleased(workflowId, et.token, et.to, amount);
        } else {
            emit EscrowPartiallyReleased(workflowId, et.token, et.to, amount, amountReleased[workflowId], et.amountAfterFee);
        }
    }
}
