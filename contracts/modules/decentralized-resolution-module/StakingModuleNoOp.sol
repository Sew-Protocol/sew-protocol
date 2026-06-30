// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './IStakingModule.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';

/**
 * @title StakingModuleNoOp
 * @notice No-op implementation of IStakingModule for testing and gradual rollout
 * @dev This is a placeholder that implements the interface but performs no actual staking logic.
 *      Used to test the integration architecture before implementing real staking.
 *
 *      All functions return success but do nothing.
 *      Events are emitted for observability.
 *
 *      WARNING: DO NOT USE IN PRODUCTION - This provides no actual stake security!
 */
contract StakingModuleNoOp is IStakingModule, AccessControl {
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_RESOLUTION_MODULE = keccak256('ROLE_RESOLUTION_MODULE');
    bytes32 public constant ROLE_SLASHING_MODULE = keccak256('ROLE_SLASHING_MODULE');

    bool public paused;

    // Dummy storage for testing (not used in logic)
    mapping(address => StakeInfo) private _dummyStakeInfo;
    mapping(address => mapping(address => DelegationInfo)) private _dummyDelegations;
    mapping(uint8 => uint256) private _dummyMinimumStakes;

    address private _dummyStakeToken;
    uint256 private _dummyUnstakePeriod;

    constructor(address initialOwner) {
        // OpenZeppelin best practice: Grant DEFAULT_ADMIN_ROLE to deployer
        // Deployment scripts will transfer this to TimelockController
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

        paused = false;
        _dummyUnstakePeriod = 7 days;
        _dummyMinimumStakes[0] = 1000 ether; // Standard resolver
        _dummyMinimumStakes[1] = 10000 ether; // Senior resolver
    }

    // ============ Core Staking Functions (No-Op) ============

    function stake(uint256 amount) external override {
        emit StakeDeposited(_msgSender(), amount, amount);
    }

    function requestUnstake(uint256 amount) external override {
        uint256 availableAt = block.timestamp + _dummyUnstakePeriod;
        emit UnstakeRequested(_msgSender(), amount, availableAt);
    }

    function cancelUnstake() external override {
        emit UnstakeCancelled(_msgSender(), 0);
    }

    function completeUnstake() external override {
        emit StakeWithdrawn(_msgSender(), 0, 0);
    }

    function emergencyWithdraw(address to) external override {
        emit EmergencyWithdrawal(_msgSender(), 0, to);
    }

    // ============ Delegation Functions (No-Op) ============

    function delegateStake(address resolver, uint256 amount) external override {
        emit StakeDelegated(_msgSender(), resolver, amount);
    }

    function undelegateStake(address resolver, uint256 amount) external override {
        emit StakeUndelegated(_msgSender(), resolver, amount);
    }

    // ============ Lifecycle Hooks (No-Op) ============

    function onResolverAssigned(
        uint256 workflowId,
        address /* escrowContract */,
        address resolver,
        uint256 stakeRequired
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        // No-op: In real implementation, would lock stake
        emit StakeLocked(resolver, stakeRequired, workflowId, 'Assignment');
    }

    function onResolutionFinalized(
        uint256 workflowId,
        address /* escrowContract */,
        address resolver,
        bool /* outcome */
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        // No-op: In real implementation, would unlock stake
        emit StakeUnlocked(resolver, 0, workflowId);
    }

    function onDisputeEscalated(
        uint256 workflowId,
        address /* escrowContract */,
        address resolver
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        // No-op: In real implementation, would unlock stake from prior round
        emit StakeUnlocked(resolver, 0, workflowId);
    }

    function lockStake(
        uint256 workflowId,
        address /* escrowContract */,
        address resolver,
        uint256 amount,
        uint256 /* duration */
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        emit StakeLocked(resolver, amount, workflowId, 'Manual lock');
    }

    function unlockStake(
        uint256 workflowId,
        address /* escrowContract */,
        address resolver
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        emit StakeUnlocked(resolver, 0, workflowId);
    }

    function creditStakeForVindication(address /* resolver */, uint256 /* amount */) external override onlyRole(ROLE_SLASHING_MODULE) {
        // No-op: In real implementation, would credit resolver's stake
    }

    // ============ Query Functions (No-Op - return dummy data) ============

    function getStakeInfo(address /* resolver */) external pure override returns (StakeInfo memory info) {
        // Return dummy data indicating "sufficient" stake
        return
            StakeInfo({
                totalStake: 10000 ether,
                availableStake: 10000 ether,
                lockedStake: 0,
                delegatedFrom: 0,
                delegatedTo: 0,
                slashedAmount: 0,
                unstakeRequestedAt: 0,
                unstakeAmount: 0,
                status: StakeStatus.ACTIVE
            });
    }

    function isStakeSufficient(
        address /* resolver */,
        uint256 /* required */
    ) external pure override returns (bool sufficient) {
        // Always return true in no-op mode
        return true;
    }

    function getAvailableStake(
        address /* resolver */
    ) external pure override returns (uint256 available) {
        return 10000 ether; // Dummy value
    }

    function getEffectiveStake(
        address /* resolver */
    ) external pure override returns (uint256 effective) {
        return 10000 ether; // Dummy value
    }

    function getDelegationInfo(
        address delegator,
        address delegatee
    ) external pure override returns (DelegationInfo memory info) {
        return
            DelegationInfo({
                delegator: delegator,
                delegatee: delegatee,
                amount: 0,
                delegatedAt: 0,
                active: false
            });
    }

    function getActiveDelegation(
        address delegator
    ) external pure override returns (DelegationInfo memory info) {
        return
            DelegationInfo({
                delegator: delegator,
                delegatee: address(0),
                amount: 0,
                delegatedAt: 0,
                active: false
            });
    }

    function getMinimumStake(uint8 tier) external view override returns (uint256 minimum) {
        return _dummyMinimumStakes[tier];
    }

    function getStakeToken() external view override returns (address token) {
        return _dummyStakeToken;
    }

    function getMaxEscrowPerCase(address) external pure override returns (uint256 maxEscrow) {
        return type(uint256).max;
    }

    function isPaused() external view override returns (bool) {
        return paused;
    }

    // ============ Admin Functions (No-Op) ============

    function setMinimumStake(
        uint8 tier,
        uint256 minimum
    ) external override onlyRole(ROLE_TIMELOCK) {
        uint256 oldMinimum = _dummyMinimumStakes[tier];
        _dummyMinimumStakes[tier] = minimum;
        emit MinimumStakeUpdated(tier, oldMinimum, minimum);
    }

    function setUnstakePeriod(uint256 period) external override onlyRole(ROLE_TIMELOCK) {
        uint256 oldPeriod = _dummyUnstakePeriod;
        _dummyUnstakePeriod = period;
        emit UnstakePeriodUpdated(oldPeriod, period);
    }

    function pause(string memory reason) external override onlyRole(ROLE_TIMELOCK) {
        paused = true;
        emit EmergencyPaused(_msgSender(), reason);
    }

    function unpause() external override onlyRole(ROLE_TIMELOCK) {
        paused = false;
        emit EmergencyUnpaused(_msgSender());
    }

    // ============ Setup Functions ============

    function setResolutionModule(address module) external onlyRole(ROLE_TIMELOCK) {
        _grantRole(ROLE_RESOLUTION_MODULE, module);
    }

    function setSlashingModule(address module) external onlyRole(ROLE_TIMELOCK) {
        _grantRole(ROLE_SLASHING_MODULE, module);
    }

    function setStakeToken(address token) external onlyRole(ROLE_TIMELOCK) {
        address oldToken = _dummyStakeToken;
        _dummyStakeToken = token;
        emit StakeTokenUpdated(oldToken, token);
    }
}
