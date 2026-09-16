// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './EscrowConfiguration.sol';
import '../interfaces/IYieldModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
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
        if (explicitSelection && customResolver != address(0)) revert ResolutionConfigWithCustomResolver(customResolver);
        if (explicitSelection && requestedVersion == 0) revert ResolutionConfigUnavailable(resolutionModule, requestedVersion);
        if (resolutionModule == address(0) || resolutionModule.code.length == 0) {
            if (requestedVersion != 0) revert ResolutionConfigUnavailable(resolutionModule, requestedVersion);
            return 0;
        }
        if (requestedVersion == 0) {
            (bool ok, bytes memory data) = resolutionModule.staticcall(abi.encodeWithSignature('activeResolutionConfigVersion()'));
            if (!ok || data.length < 32) return 0;
            version = abi.decode(data, (uint256));
        } else version = requestedVersion;
        if (!explicitSelection) return version;
        (bool selectable, bytes memory selectableData) = resolutionModule.staticcall(
            abi.encodeWithSignature('isResolutionConfigSelectable(uint256)', version)
        );
        if (!selectable || selectableData.length < 32 || !abi.decode(selectableData, (bool))) {
            revert ResolutionConfigUnavailable(resolutionModule, version);
        }
    }

    function _snapshotModulesForEscrow(uint256 workflowId, uint256 resolutionConfigVersion) internal {
        address resModule = address(_getResolutionModule(workflowId));
        moduleSnapshots[workflowId] = ModuleSnapshot({
            resolutionModule: resModule, releaseStrategy: address(_getReleaseStrategy(workflowId)),
            cancellationStrategy: _getCancellationStrategy(workflowId),
            yieldGenerationModule: address(_getYieldGenerationModule(workflowId)),
            yieldDistributionModule: address(_getYieldDistributionModule(workflowId)),
            incentiveModule: ModuleSnapshotLibrary.getIncentiveModule(resModule),
            yieldProtocolFeeBps: yieldProtocolFeeBps, appealBondProtocolFeeBps: appealBondProtocolFeeBps,
            escrowFeeBps: escrowFee, defaultAutoReleaseDelay: timeoutConfig.defaultAutoReleaseDelay,
            defaultAutoCancelDelay: timeoutConfig.defaultAutoCancelDelay, maxDisputeDuration: timeoutConfig.maxDisputeDuration,
            appealWindowDuration: timeoutConfig.appealWindowDuration
        });
        if (resolutionConfigVersion != 0) {
            workflowResolutionConfigVersion[workflowId] = resolutionConfigVersion;
            (bool ok, bytes memory data) = resModule.staticcall(abi.encodeWithSignature('resolutionConfigRoot(uint256)', resolutionConfigVersion));
            bytes32 root = ok && data.length >= 32 ? abi.decode(data, (bytes32)) : bytes32(0);
            emit ResolutionConfigBound(workflowId, resModule, resolutionConfigVersion, root);
        }
        bool pending = timeoutConfig.defaultAutoCancelDelay > 0;
        bool disputed = timeoutConfig.maxDisputeDuration > 0;
        timeoutPolicySnapshots[workflowId] = EscrowTimeoutPolicySnapshot(pending, disputed);
        appealBondFeeRecipients[workflowId] = escrowFeeAddress;
        emit TimeoutPolicySnapshotted(workflowId, pending, disputed);
    }

    /// @dev Creation-time derivation/materialization of a workflow's settings.
    ///      Sets the custom resolver, derives auto-release/auto-cancel times from
    ///      creation-time defaults, enforces mutual exclusion, stores the settings,
    ///      and emits the configuration event.
    function _applyEscrowSettings(uint256 workflowId, EscrowSettings memory settings) internal {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if (settings.customResolver != address(0)) et.disputeResolver = settings.customResolver;
        bool useDefaults = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);

        uint256 relTime = settings.autoReleaseTime;
        if (relTime == 0 && useDefaults && timeoutConfig.defaultAutoReleaseDelay > 0) {
            relTime = block.timestamp + timeoutConfig.defaultAutoReleaseDelay;
        }
        if (relTime > type(uint64).max) revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, relTime, block.timestamp);
        et.autoReleaseTime = uint64(relTime);

        uint256 cancTime = settings.autoCancelTime;
        if (cancTime == 0 && useDefaults && timeoutConfig.defaultAutoCancelDelay > 0) {
            cancTime = block.timestamp + timeoutConfig.defaultAutoCancelDelay;
        }
        if (cancTime > type(uint64).max) revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, cancTime, block.timestamp);
        et.autoCancelTime = uint64(cancTime);

        // Independent mutual-exclusion check (guards against setTimeoutConfig bypass
        // or future code changes that could set both defaults simultaneously).
        if (et.autoReleaseTime > 0 && et.autoCancelTime > 0) {
            revert BothAutoTimesSet(workflowId, et.autoReleaseTime, et.autoCancelTime);
        }

        escrowSettings[workflowId] = settings;
        emit EscrowSettingsUpdated(workflowId, settings);
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
    function _getYieldDistributionModule(uint256 workflowId) internal view virtual returns (IYieldDistributionModule);
}
