// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './BaseEscrow.sol';
import './ModuleSnapshotRegistry.sol';
import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldModule.sol';
import '../libraries/BalanceUpdateLibrary.sol';
import '../libraries/FeeRecordingLibrary.sol';
import '../libraries/EscrowVaultAccountingLibrary.sol';
import '../libraries/ModuleGetterLibrary.sol';
import '../libraries/FeeWithdrawalLibrary.sol';

/// @notice Minimal single-resolver ERC-20 escrow profile for Sew deployments.
/// @dev Appeals, split proposals, partial release, and yield are explicitly
///      unavailable in this profile. The full EscrowVault remains unchanged.
contract SewCoreVault is BaseEscrow {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public totalFeesPerToken;
    mapping(address => uint256) public totalHeldInEscrowPerToken;
    ModuleSnapshotRegistry public immutable moduleManagement;
    bytes32 public constant ROLE_FEE_RECIPIENT = keccak256('ROLE_FEE_RECIPIENT');

    event FeesWithdrawn(address indexed token, uint256 amount);

    error CoreFeatureDisabled();

    constructor(uint256 escrowFeeBps, address feeAddress, address moduleManagementAddress) {
        address deployer = _msgSender();
        _grantRole(DEFAULT_ADMIN_ROLE, deployer);
        _grantRole(ROLE_TIMELOCK, deployer);
        if (escrowFeeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(escrowFeeBps, MAX_ESCROW_FEE_BPS);
        if (feeAddress == address(0)) revert ZeroAddress(1);
        if (moduleManagementAddress == address(0) || moduleManagementAddress.code.length == 0) revert ZeroAddress(4);
        escrowFee = escrowFeeBps;
        escrowFeeAddress = feeAddress;
        moduleManagement = ModuleSnapshotRegistry(moduleManagementAddress);
        timeoutConfig.maxDisputeDuration = 90 days;
        timeoutConfig.appealWindowDuration = 0;
    }

    function _pullTokens(address token, address from, uint256 amount) internal override {
        IERC20(token).safeTransferFrom(from, address(this), amount);
    }

    function _recordFee(address token, uint256 amount) internal override {
        FeeRecordingLibrary.recordFee(totalFeesPerToken, token, amount);
    }

    function _validateProfileSettings(EscrowSettings memory settings) internal pure override {
        if (settings.yieldPreset != YieldPreset.OFF) revert CoreFeatureDisabled();
    }

    function _depositForYield(IYieldModule, uint256, address, uint256) internal pure override {
        revert CoreFeatureDisabled();
    }

    function _depositYieldForEscrow(uint256, address, uint256) internal pure override {
        revert CoreFeatureDisabled();
    }

    function _handleYieldModuleUnwind(uint256, address, uint256 amount)
        internal pure override returns (uint256 principalOut, uint256 yieldOut)
    {
        return (amount, 0);
    }

    function _transferTokens(address token, address to, uint256 amount) internal override {
        IERC20(token).safeTransfer(to, amount);
    }

    function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
        BalanceUpdateLibrary.updateBalance(totalHeldInEscrowPerToken, token, amount, add);
    }

    function _getYieldGenerationModule(uint256) internal pure override returns (IYieldModule) {
        return IYieldModule(address(0));
    }

    function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
        return IReleaseStrategy(ModuleGetterLibrary.getModuleAddress(workflowId, ModuleType.RELEASE, moduleSnapshots, moduleManagement, address(this)));
    }

    function _getCancellationStrategy(uint256 workflowId) internal view override returns (address) {
        return ModuleGetterLibrary.getModuleAddress(workflowId, ModuleType.CANCELLATION, moduleSnapshots, moduleManagement, address(this));
    }

    function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
        address moduleAddr = ModuleGetterLibrary.getModuleAddress(workflowId, ModuleType.RESOLUTION, moduleSnapshots, moduleManagement, address(this));
        return IResolutionModule(moduleAddr != address(0) ? moduleAddr : disputeResolutionModule);
    }

    function withdrawFees(address token) external nonReentrant onlyRole(ROLE_FEE_RECIPIENT) {
        uint256 amount = FeeWithdrawalLibrary.withdrawFees(totalFeesPerToken, token, escrowFeeAddress);
        emit FeesWithdrawn(token, amount);
    }

    function _supportsAppealInterface() internal pure override returns (bool) { return false; }

}
