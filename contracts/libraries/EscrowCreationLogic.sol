// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../core/EscrowStorage.sol';
import '../libraries/ModuleSnapshotLibrary.sol';
import '../libraries/SettingsValidationLibrary.sol';
import '../libraries/YieldPresetLibrary.sol';
import '../libraries/EscrowEncodingLibrary.sol';
import '../shared/interfaces/IResolutionModule.sol';

/**
 * @title EscrowCreationLogic
 * @notice Compile-time escrow creation derivation, mirroring the externally
 *         deployed CreateOps contract.
 *
 * @dev Preserves the CreateOps separation of concerns:
 *      - derive only: returns a result (or reverts), never mutates escrow state
 *      - no callbacks, no escrow storage access
 *      - all inputs explicit, including the two policy flags that CreateOps owned
 *        as mutable state (`resolverMustBeContract`, `yieldDepositsPaused`) and
 *        the escrow address reported to the resolution module.
 *
 *      The escrow remains the sole authoritative mutator: it calls this function,
 *      then applies the derived result to escrow state. This keeps the
 *      derive -> result -> apply boundary.
 *
 *      NOTE: this library is wired into production — `EscrowCreation.computeEscrowCreation`
 *      is the authoritative derivation path. Differential equivalence against the legacy
 *      CreateOps reference is preserved in test/foundry/ops/CreationLogicEquivalence.t.sol.
 */
library EscrowCreationLogic {
    error BothAutoTimesSet(uint256 workflowId, uint64 releaseTime, uint64 cancelTime);
    event EscrowSettingsUpdated(uint256 indexed workflowId, EscrowSettings settings);
    event ResolutionConfigBound(uint256 indexed workflowId, address indexed resolutionModule, uint256 indexed version, bytes32 resolutionConfigRoot);
    event TimeoutPolicySnapshotted(uint256 indexed workflowId, bool pendingAutoCancelEnabled, bool disputedTimeoutEnabled);
    error ResolutionConfigUnavailable(address resolutionModule, uint256 version);
    error ResolutionConfigWithCustomResolver(address customResolver);
    uint256 private constant ESCROW_FEE_DENOMINATOR = 10000;

    /// @dev Result of escrow creation computation (matches CreateOps.CreateResult).
    struct CreateResult {
        uint256 fee; // Escrow fee amount
        uint256 amountAfterFee; // Amount after fee deduction
        address resolver; // Default resolver address
        bool yieldEnabled; // Whether yield is enabled for this escrow
        bool shouldDepositYield; // Whether to attempt yield deposit
    }

    /**
     * @notice Compute escrow creation parameters.
     * @dev Compute-only: does not modify escrow state. Reverts identically to
     *      CreateOps for invalid inputs.
     * @param escrowContract Address reported to the resolution module (equivalent
     *        to CreateOps' `_msgSender()`, which is the calling escrow).
     * @param resolverMustBeContract Policy flag formerly owned by CreateOps.
     * @param yieldDepositsPaused Policy flag formerly owned by CreateOps.
     */
    function computeEscrowCreation(
        address token,
        address to,
        address from,
        uint256 amount,
        EscrowSettings memory settings,
        uint256 escrowFee,
        uint256 workflowId,
        address resolutionModule,
        address escrowContract,
        bool resolverMustBeContract,
        bool yieldDepositsPaused
    ) public view returns (CreateResult memory result) {
        // Validate inputs
        if (token == address(0)) revert InvalidAddress(ADDR_TOKEN, token);
        if (amount == 0) revert AmountZero();
        SettingsValidationLibrary.validateEscrowAmount(amount);
        SettingsValidationLibrary.validateRecipient(to, from, settings.releaseAddress);

        // Use explicit validation time (always block.timestamp in production)
        uint256 validationTime = block.timestamp;
        SettingsValidationLibrary.validateEscrowSettings(settings, validationTime, resolverMustBeContract);

        // Fee calculation: fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR
        result.fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;
        result.amountAfterFee = amount - result.fee;

        // Resolver determination: Query resolution module for default resolver
        result.resolver = _getDisputeResolverForNewEscrow(
            resolutionModule,
            workflowId,
            token,
            from,
            to,
            result.amountAfterFee,
            escrowContract
        );

        // Yield configuration
        result.yieldEnabled = YieldPresetLibrary.isYieldEnabled(settings.yieldPreset);
        if (result.yieldEnabled && !yieldDepositsPaused) {
            // Validate preset parameters (sender and recipient addresses)
            YieldPresetLibrary.validatePresetParams(settings.yieldPreset, from, to);
            // Validate yield opt-in amount (graceful degradation)
            result.shouldDepositYield = SettingsValidationLibrary.validateYieldOptIn(result.amountAfterFee, true);
        } else {
            result.shouldDepositYield = false;
        }

        return result;
    }

    /**
     * @dev Best-effort resolver lookup. Mirrors CreateOps._getDisputeResolverForNewEscrow.
     */
    function _getDisputeResolverForNewEscrow(
        address resolutionModule,
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount,
        address escrowContract
    ) internal view returns (address resolver) {
        if (resolutionModule == address(0)) {
            return address(0);
        }

        // Check if resolutionModule is a contract (has code)
        if (resolutionModule.code.length == 0) {
            return address(0);
        }

        // Use low-level staticcall to query module
        bytes memory escrowData = EscrowEncodingLibrary.encodeEscrowTransferData(token, from, to, amount, address(0)); // Pass address(0) for releaseAddress as it's not relevant for resolver lookup
        (bool success, bytes memory data) = resolutionModule.staticcall(
            abi.encodeWithSelector(
                IResolutionModule.getDisputeResolver.selector,
                workflowId,
                escrowContract,
                escrowData
            )
        );

        if (!success || data.length < 64) {
            return address(0);
        }

        (resolver, ) = abi.decode(data, (address, uint8));
        return resolver;
    }
    /// @notice Persist the module and timeout configuration observed at creation.
    function snapshotModulesForEscrow(
        mapping(uint256 => ModuleSnapshot) storage snapshots,
        mapping(uint256 => uint256) storage resolutionConfigVersions,
        mapping(uint256 => EscrowStorage.EscrowTimeoutPolicySnapshot) storage timeoutPolicies,
        mapping(uint256 => address) storage appealFeeRecipients,
        uint256 workflowId,
        address resolutionModule,
        address releaseStrategy,
        address cancellationStrategy,
        address yieldGenerationModule,
        uint256 resolutionConfigVersion,
        uint256 yieldProtocolFeeBps,
        uint256 appealBondProtocolFeeBps,
        uint256 escrowFeeBps,
        TimeoutConfig memory timeoutConfig,
        address feeRecipient
    ) public {
        snapshots[workflowId] = ModuleSnapshot({
            resolutionModule: resolutionModule,
            releaseStrategy: releaseStrategy,
            cancellationStrategy: cancellationStrategy,
            yieldGenerationModule: yieldGenerationModule,
            incentiveModule: ModuleSnapshotLibrary.getIncentiveModule(resolutionModule),
            yieldProtocolFeeBps: yieldProtocolFeeBps,
            appealBondProtocolFeeBps: appealBondProtocolFeeBps,
            escrowFeeBps: escrowFeeBps,
            defaultAutoReleaseDelay: timeoutConfig.defaultAutoReleaseDelay,
            defaultAutoCancelDelay: timeoutConfig.defaultAutoCancelDelay,
            maxDisputeDuration: timeoutConfig.maxDisputeDuration,
            appealWindowDuration: timeoutConfig.appealWindowDuration
        });
        if (resolutionConfigVersion != 0) {
            resolutionConfigVersions[workflowId] = resolutionConfigVersion;
            (bool ok, bytes memory data) = resolutionModule.staticcall(
                abi.encodeWithSignature('resolutionConfigRoot(uint256)', resolutionConfigVersion)
            );
            bytes32 root = ok && data.length >= 32 ? abi.decode(data, (bytes32)) : bytes32(0);
            emit ResolutionConfigBound(workflowId, resolutionModule, resolutionConfigVersion, root);
        }
        bool pending = timeoutConfig.defaultAutoCancelDelay > 0;
        bool disputed = timeoutConfig.maxDisputeDuration > 0;
        timeoutPolicies[workflowId] = EscrowStorage.EscrowTimeoutPolicySnapshot(pending, disputed);
        appealFeeRecipients[workflowId] = feeRecipient;
        emit TimeoutPolicySnapshotted(workflowId, pending, disputed);
    }

    /// @notice Materialize settings for a newly created escrow.
    /// @dev This storage-only library call preserves the state transition while
    ///      keeping profile-specific vault runtimes below EIP-170.
    function applyEscrowSettings(
        EscrowTransfer storage et,
        mapping(uint256 => EscrowSettings) storage escrowSettingsByWorkflow,
        uint256 workflowId,
        EscrowSettings memory settings,
        uint256 defaultAutoReleaseDelay,
        uint256 defaultAutoCancelDelay
    ) public {
        if (settings.customResolver != address(0)) et.disputeResolver = settings.customResolver;
        bool useDefaults = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);
        uint256 relTime = settings.autoReleaseTime;
        if (relTime == 0 && useDefaults && defaultAutoReleaseDelay > 0) relTime = block.timestamp + defaultAutoReleaseDelay;
        if (relTime > type(uint64).max) revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, relTime, block.timestamp);
        et.autoReleaseTime = uint64(relTime);
        uint256 cancTime = settings.autoCancelTime;
        if (cancTime == 0 && useDefaults && defaultAutoCancelDelay > 0) cancTime = block.timestamp + defaultAutoCancelDelay;
        if (cancTime > type(uint64).max) revert InvalidAutoTime(AUTO_TIME_TOO_LARGE, cancTime, block.timestamp);
        et.autoCancelTime = uint64(cancTime);
        if (et.autoReleaseTime > 0 && et.autoCancelTime > 0) {
            revert BothAutoTimesSet(workflowId, et.autoReleaseTime, et.autoCancelTime);
        }
        escrowSettingsByWorkflow[workflowId] = settings;
        emit EscrowSettingsUpdated(workflowId, settings);
    }

    /// @notice Resolve and validate a selected resolution-config version.
    /// @dev Shared by vault profiles; keeping this helper linked avoids inlining
    ///      repeated module-probing logic into each vault runtime.
    function resolveResolutionConfigVersion(address resolutionModule, uint256 requestedVersion, address customResolver, bool explicitSelection)
        public view returns (uint256 version)
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

}
