// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/access/AccessControl.sol';

/**
 * @title EscrowCreationPolicy
 * @notice Shared, protocol-wide escrow creation policy.
 *
 * @dev This is the deliberately narrow remnant of the former CreateOps contract.
 *      It owns only global policy state and its governance surface:
 *        - yieldDepositsPaused     (emergency, protocol-wide)
 *        - resolverMustBeContract  (resolver policy)
 *
 *      It contains no calculation, no resolver lookup, no fee logic, and no
 *      creation orchestration. Deterministic creation derivation lives in
 *      EscrowCreationLogic; orchestration lives in BaseEscrow.
 *
 *      Keeping this a single shared authority preserves the global semantics of
 *      the emergency yield-deposit pause: one governance/guardian action affects
 *      creation for every escrow product, rather than requiring N transactions
 *      and leaving partial-pause states.
 */
contract EscrowCreationPolicy is AccessControl {
    // ============ Role Constants ============
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    // ============ Policy State ============
    /// @notice Pause flag for yield deposits (emergency control, protocol-wide)
    bool public yieldDepositsPaused;

    /// @notice Policy flag: whether a non-zero `customResolver` must be a contract.
    /// @dev Default `true`. This flag gates exactly one check: at creation,
    ///      `SettingsValidationLibrary.validateEscrowSettings` rejects a
    ///      `customResolver` with no code when the flag is true.
    ///
    ///      IMPORTANT — admission-only. This flag affects the admission of NEW
    ///      escrows only. Changing the policy does NOT alter the resolver or the
    ///      authority of any existing escrow: an escrow's resolver is captured in
    ///      `escrowSettings[workflowId].customResolver` / `escrowTransfers[workflowId].disputeResolver`
    ///      at creation and is thereafter immutable for that workflow.
    ///
    ///      Consequences of `false` (specified, not merely tolerated). `false`
    ///      permits a non-zero EOA `customResolver`, which means:
    ///        - that address is the workflow's resolver authority
    ///          (`BaseEscrow._isAuthorizedDisputeResolver` treats it as the sole resolver);
    ///        - resolver callbacks are unavailable (`DisputeInitializationLibrary.callResolverCallback`
    ///          returns early for code-less resolvers);
    ///        - appeals are unsupported for that custom-resolver workflow
    ///          (`BaseEscrow._appealDispute` reverts `AppealsUnsupportedForCustomResolver`);
    ///        - settlement/custody execution is unchanged (same terminal transitions
    ///          and pull-only entitlements as any other resolution).
    ///
    ///      The production default is `true`, and deployments use contract resolvers
    ///      (e.g. a forwarding resolver) even when an EOA owns resolution. `false` is
    ///      a deliberately tested, end-to-end supported compatibility mode — retained
    ///      as an explicit policy choice, not dead code — but is not used by any
    ///      deployment. (See `docs/architecture/ARCHITECTURAL_PRINCIPLES.md`.)
    bool public resolverMustBeContract = true;

    // ============ Custom Errors ============
    error ZeroOwner();
    error AlreadyPaused();
    error NotPaused();
    error NotAuthorized(address caller);

    // ============ Events ============
    event YieldDepositsPaused(address indexed caller, string reason);
    event YieldDepositsResumed(address indexed caller);
    event ResolverPolicyUpdated(bool mustBeContract);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(ROLE_TIMELOCK, initialOwner);
    }

    /**
     * @notice Pause yield deposits (emergency control)
     * @dev Callable by ROLE_GUARDIAN (emergency) or ROLE_TIMELOCK (governance).
     *      Reverts if already paused.
     */
    function pauseYieldDeposits(string memory reason) external {
        if (!hasRole(ROLE_TIMELOCK, _msgSender()) && !hasRole(ROLE_GUARDIAN, _msgSender())) {
            revert NotAuthorized(_msgSender());
        }
        if (yieldDepositsPaused) revert AlreadyPaused();

        yieldDepositsPaused = true;
        emit YieldDepositsPaused(_msgSender(), reason);
    }

    /**
     * @notice Resume yield deposits
     * @dev Only callable by ROLE_TIMELOCK. Guardian is down-only and cannot resume.
     *      Reverts if deposits are not paused.
     */
    function resumeYieldDeposits() external onlyRole(ROLE_TIMELOCK) {
        if (!yieldDepositsPaused) revert NotPaused();

        yieldDepositsPaused = false;
        emit YieldDepositsResumed(_msgSender());
    }

    /**
     * @notice Set whether customResolver must be a contract
     * @dev Only callable by ROLE_TIMELOCK (governance-controlled).
     */
    function setResolverPolicy(bool mustBeContract) external onlyRole(ROLE_TIMELOCK) {
        resolverMustBeContract = mustBeContract;
        emit ResolverPolicyUpdated(mustBeContract);
    }
}
