// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './BaseEscrow.sol';
import '../types/EscrowTypes.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import './ModuleManagementContract.sol';
import '../libraries/ModuleGetterLibrary.sol';
import '../libraries/FeeRecordingLibrary.sol';
import '../libraries/BalanceUpdateLibrary.sol';
import '../libraries/ModuleGetterConsolidationLibrary.sol';
import '../libraries/FeeWithdrawalLibrary.sol';
import '../libraries/TokenRecoveryLibrary.sol';

contract EscrowVault is BaseEscrow {
    using SafeERC20 for IERC20;


    mapping(address => uint256) public totalFeesPerToken;
    mapping(address => uint256) public totalHeldInEscrowPerToken;

    ModuleManagementContract public moduleManagement;

    event FeesWithdrawn(address indexed token, uint256 amount);

    error ZeroAddress(uint8 which);

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
        escrowFee = escrowFeeBps;
        escrowFeeAddress = feeAddress;
        moduleManagement = ModuleManagementContract(moduleManagementAddress);
        yieldOps = YieldOps(yieldOpsAddress);
        disputeOps = DisputeOps(disputeOpsAddress);
        yieldProtocolFeeBps = 3000; // 30% default
        timeoutConfig.maxDisputeDuration = 90 days;
        timeoutConfig.appealWindowDuration = 2 days;
    }


    function releaseEscrowTransfer(uint256 workflowId) public nonReentrant whenNotPaused {
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
    function _depositForYield(
        IYieldGenerationModule generationModule,
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal override {
        generationModule.depositForYield(workflowId, token, amount);
    }
    function _emitEscrowTransferCreated(uint256, address, address, address, uint256) internal pure override {}
    function _transferTokens(address token, address to, uint256 amount) internal override {
        IERC20(token).safeTransfer(to, amount);
    }
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
        BalanceUpdateLibrary.updateBalance(totalHeldInEscrowPerToken, token, amount, add);
    }
    function _emitEscrowTransferCancelled(uint256, address, address, uint256) internal pure override {}
    function _emitEscrowTransferReleased(uint256, address, address, uint256) internal pure override {}

    function _getModuleAddress(uint256 workflowId, ModuleType moduleType) internal view returns (address) {
        return ModuleGetterLibrary.getModuleAddress(
            workflowId,
            moduleType,
            moduleSnapshots,
            moduleManagement,
            address(this)
        );
    }

    function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
        return ModuleGetterConsolidationLibrary.getReleaseStrategy(_getModuleAddress(workflowId, ModuleType.RELEASE));
    }
    function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
        return ModuleGetterConsolidationLibrary.getResolutionModule(_getModuleAddress(workflowId, ModuleType.RESOLUTION), disputeResolutionModule);
    }
    function _getYieldGenerationModule(uint256 workflowId) internal view override returns (IYieldGenerationModule) {
        return ModuleGetterConsolidationLibrary.getYieldGenerationModule(_getModuleAddress(workflowId, ModuleType.YIELD_GEN));
    }
    function _getYieldDistributionModule(uint256 workflowId) internal view override returns (IYieldDistributionModule) {
        return ModuleGetterConsolidationLibrary.getYieldDistributionModule(_getModuleAddress(workflowId, ModuleType.YIELD_DIST));
    }

    function _getDefaultYieldGenerationModule() internal view override returns (IYieldGenerationModule module) {
        return IYieldGenerationModule(moduleManagement.getModule(address(this), ModuleType.YIELD_GEN));
    }

    function queueModule(BaseEscrow.ModuleType moduleType, address newModule) external onlyRole(ROLE_TIMELOCK) {
        moduleManagement.queueModule(address(this), moduleType, newModule);
    }

    function activateModule(BaseEscrow.ModuleType moduleType) external onlyRole(ROLE_TIMELOCK) {
        moduleManagement.activateModule(address(this), moduleType);
    }

    bytes32 public constant ROLE_FEE_RECIPIENT = keccak256('ROLE_FEE_RECIPIENT');

    function withdrawFees(address token) external onlyRole(ROLE_FEE_RECIPIENT) nonReentrant {
        uint256 feeAmount = FeeWithdrawalLibrary.withdrawFees(totalFeesPerToken, token, escrowFeeAddress);
        emit FeesWithdrawn(token, feeAmount);
    }

    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external override onlyRole(ROLE_TIMELOCK) nonReentrant {
        (bool success, uint256 recoveryAmount, uint256 available) = TokenRecoveryLibrary.recoverERC20(
            totalHeldInEscrowPerToken,
            totalFeesPerToken,
            token,
            recipient,
            amount
        );
        if (!success) revert AmountExceedsAvailable(token, recoveryAmount, available);
        emit ERC20Recovered(token, recipient, recoveryAmount);
    }
}
