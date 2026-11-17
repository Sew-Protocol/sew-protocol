// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './EscrowConfiguration.sol';
import '../interfaces/IYieldModule.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../libraries/EscrowCreationLogic.sol';
import '../libraries/ModuleSnapshotLibrary.sol';
import '../types/EscrowTypes.sol';

/// @notice Shared escrow creation implementation for all escrow products.
abstract contract EscrowCreation is ReentrancyGuard, EscrowConfiguration {
    error AccountingDeficit(address token, uint256 deficit);
    error ResolutionConfigUnavailable(address resolutionModule, uint256 version);
    error ResolutionConfigWithCustomResolver(address customResolver);
    error BothAutoTimesSet(uint256 workflowId, uint64 releaseTime, uint64 cancelTime);
    event EscrowStateChanged(uint256 indexed workflowId, EscrowState oldStatus, EscrowState newStatus);
    event EscrowCreated(uint256 indexed workflowId, address indexed token, address indexed from, address to, uint256 amount, uint256 amountAfterFee, uint256 fee);
    event ResolutionConfigBound(uint256 indexed workflowId, address indexed resolutionModule, uint256 indexed version, bytes32 resolutionConfigRoot);
    event TimeoutPolicySnapshotted(uint256 indexed workflowId, bool pendingAutoCancelEnabled, bool disputedTimeoutEnabled);
    event EscrowSettingsUpdated(uint256 indexed workflowId, EscrowSettings settings);

    function createEscrow(address token, address to, uint256 amount, EscrowSettings memory settings)
        public nonReentrant returns (uint256)
    {
        return _createEscrow(token, to, amount, settings, 0, false);
    }

    function _createEscrow(address token, address to, uint256 amount, EscrowSettings memory settings,
        uint256 requestedResolutionConfigVersion, bool explicitResolutionConfigSelection)
        internal returns (uint256)
    {
        _requireNotPaused();
        _validateProfileSettings(settings, token);
        uint256 workflowId = escrowTransfers.length;
        if (address(creationPolicy) == address(0)) revert ZeroCreationPolicy();
        IResolutionModule resolutionModule = _getResolutionModule(workflowId);
        uint256 resolutionConfigVersion = _resolveResolutionConfigVersion(
            address(resolutionModule), requestedResolutionConfigVersion, settings.customResolver,
            explicitResolutionConfigSelection
        );

        // Snapshot the shared policy once so a single creation transition has a
        // coherent policy basis (no scattered, possibly-inconsistent reads).
        bool resolverMustBeContract = creationPolicy.resolverMustBeContract();
        bool yieldDepositsPaused = creationPolicy.yieldDepositsPaused();

        EscrowCreationLogic.CreateResult memory result = EscrowCreationLogic.computeEscrowCreation(
            token, to, _msgSender(), amount, settings, escrowFee, workflowId, address(resolutionModule),
            address(this), resolverMustBeContract, yieldDepositsPaused
        );

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        _pullTokens(token, _msgSender(), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received < amount) revert AccountingDeficit(token, amount - received);

        escrowTransfers.push(EscrowTransfer({
            token: token, to: to, from: _msgSender(), amountAfterFee: result.amountAfterFee,
            escrowState: EscrowState.PENDING, senderStatus: SenderStatus.NONE,
            recipientStatus: RecipientStatus.NONE, disputeResolver: result.resolver,
            autoReleaseTime: 0, autoCancelTime: 0
        }));
        _updateEscrowBalance(token, result.amountAfterFee, true);
        _recordFee(token, result.fee);
        _applyEscrowSettings(workflowId, settings);
        _snapshotModulesForEscrow(workflowId, resolutionConfigVersion);
        if (result.yieldEnabled && result.shouldDepositYield) _depositYieldForEscrow(workflowId, token, result.amountAfterFee);
        emit EscrowCreated(workflowId, token, _msgSender(), to, amount, result.amountAfterFee, result.fee);
        _emitEscrowStateChanged(workflowId, EscrowState.NONE, EscrowState.PENDING);
        _emitEscrowTransferCreated(workflowId, token, _msgSender(), to, amount);
        return workflowId;
    }

    function _resolveResolutionConfigVersion(address resolutionModule, uint256 requestedVersion, address customResolver, bool explicitSelection)
        internal view returns (uint256 version)
    {
        return EscrowCreationLogic.resolveResolutionConfigVersion(resolutionModule, requestedVersion, customResolver, explicitSelection);
    }

    function _validateProfileSettings(EscrowSettings memory settings, address token) internal view virtual {
        settings;
        token;
    }

    function _snapshotModulesForEscrow(uint256 workflowId, uint256 resolutionConfigVersion) internal {
        EscrowCreationLogic.snapshotModulesForEscrow(
            moduleSnapshots, workflowResolutionConfigVersion, timeoutPolicySnapshots,
            appealBondFeeRecipients, workflowId, address(_getResolutionModule(workflowId)),
            address(_getReleaseStrategy(workflowId)), _getCancellationStrategy(workflowId),
            address(_getYieldGenerationModule(workflowId)), resolutionConfigVersion,
            yieldProtocolFeeBps, appealBondProtocolFeeBps, escrowFee,
            timeoutConfig, escrowFeeAddress
        );
    }

    /// @dev Creation-time derivation/materialization of a workflow's settings.
    ///      Sets the custom resolver, derives auto-release/auto-cancel times from
    ///      creation-time defaults, enforces mutual exclusion, stores the settings,
    ///      and emits the configuration event.
    function _applyEscrowSettings(uint256 workflowId, EscrowSettings memory settings) internal {
        EscrowCreationLogic.applyEscrowSettings(
            escrowTransfers[workflowId], escrowSettings, workflowId, settings,
            timeoutConfig.defaultAutoReleaseDelay, timeoutConfig.defaultAutoCancelDelay
        );
    }

    function _pullTokens(address token, address from, uint256 amount) internal virtual;
    function _recordFee(address token, uint256 amount) internal virtual;
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal virtual;
    function _depositYieldForEscrow(uint256 workflowId, address token, uint256 amount) internal virtual;
    function _emitEscrowTransferCreated(uint256 workflowId, address token, address from, address to, uint256 amount) internal virtual;
    function _emitEscrowStateChanged(uint256 workflowId, EscrowState oldStatus, EscrowState newStatus) internal virtual;
    function _getResolutionModule(uint256 workflowId) internal view virtual returns (IResolutionModule);
    function _getReleaseStrategy(uint256 workflowId) internal view virtual returns (IReleaseStrategy);
    function _getCancellationStrategy(uint256 workflowId) internal view virtual returns (address);
    function _getYieldGenerationModule(uint256 workflowId) internal view virtual returns (IYieldModule);
}
