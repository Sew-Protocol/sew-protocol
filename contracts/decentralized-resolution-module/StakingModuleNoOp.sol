// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "./IStakingModule.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

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
contract StakingModuleNoOp is 
    IStakingModule, 
    Initializable, 
    AccessControlUpgradeable, 
    UUPSUpgradeable 
{
    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");
    bytes32 public constant ROLE_RESOLUTION_MODULE = keccak256("ROLE_RESOLUTION_MODULE");
    
    bool public paused;
    
    // Dummy storage for testing (not used in logic)
    mapping(address => StakeInfo) private _dummyStakeInfo;
    mapping(address => mapping(address => DelegationInfo)) private _dummyDelegations;
    mapping(uint8 => uint256) private _dummyMinimumStakes;
    
    address private _dummyStakeToken;
    uint256 private _dummyUnstakePeriod;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address initialOwner) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(ROLE_ADMIN, initialOwner);
        
        paused = false;
        _dummyUnstakePeriod = 7 days;
        _dummyMinimumStakes[0] = 1000 ether; // Standard resolver
        _dummyMinimumStakes[1] = 10000 ether; // Senior resolver
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ROLE_ADMIN) {}
    
    // ============ Core Staking Functions (No-Op) ============
    
    function stake(uint256 amount) external override {
        emit StakeDeposited(msg.sender, amount, amount);
    }
    
    function requestUnstake(uint256 amount) external override {
        uint256 availableAt = block.timestamp + _dummyUnstakePeriod;
        emit UnstakeRequested(msg.sender, amount, availableAt);
    }
    
    function cancelUnstake() external override {
        emit UnstakeCancelled(msg.sender, 0);
    }
    
    function completeUnstake() external override {
        emit StakeWithdrawn(msg.sender, 0, 0);
    }
    
    function emergencyWithdraw(address to) external override {
        emit EmergencyWithdrawal(msg.sender, 0, to);
    }
    
    // ============ Delegation Functions (No-Op) ============
    
    function delegateStake(address resolver, uint256 amount) external override {
        emit StakeDelegated(msg.sender, resolver, amount);
    }
    
    function undelegateStake(address resolver, uint256 amount) external override {
        emit StakeUndelegated(msg.sender, resolver, amount);
    }
    
    // ============ Lifecycle Hooks (No-Op) ============
    
    function onResolverAssigned(
        uint256 workflowId,
        address resolver,
        uint256 stakeRequired
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        // No-op: In real implementation, would lock stake
        emit StakeLocked(resolver, stakeRequired, workflowId, "Assignment");
    }
    
    function onResolutionFinalized(
        uint256 workflowId,
        address resolver,
        bool outcome
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        // No-op: In real implementation, would unlock stake
        emit StakeUnlocked(resolver, 0, workflowId);
    }
    
    function onDisputeEscalated(
        uint256 workflowId,
        address resolver
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        // No-op: In real implementation, would unlock stake from prior round
        emit StakeUnlocked(resolver, 0, workflowId);
    }
    
    function lockStake(
        uint256 workflowId,
        address resolver,
        uint256 amount,
        uint256 duration
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        emit StakeLocked(resolver, amount, workflowId, "Manual lock");
    }
    
    function unlockStake(
        uint256 workflowId,
        address resolver
    ) external override onlyRole(ROLE_RESOLUTION_MODULE) {
        emit StakeUnlocked(resolver, 0, workflowId);
    }
    
    // ============ Query Functions (No-Op - return dummy data) ============
    
    function getStakeInfo(address resolver) external view override returns (StakeInfo memory info) {
        // Return dummy data indicating "sufficient" stake
        return StakeInfo({
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
    
    function isStakeSufficient(address resolver, uint256 required) 
        external 
        view 
        override 
        returns (bool sufficient) 
    {
        // Always return true in no-op mode
        return true;
    }
    
    function getAvailableStake(address resolver) external view override returns (uint256 available) {
        return 10000 ether; // Dummy value
    }
    
    function getEffectiveStake(address resolver) external view override returns (uint256 effective) {
        return 10000 ether; // Dummy value
    }
    
    function getDelegationInfo(address delegator, address delegatee) 
        external 
        view 
        override 
        returns (DelegationInfo memory info) 
    {
        return DelegationInfo({
            delegator: delegator,
            delegatee: delegatee,
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
    
    function isPaused() external view override returns (bool) {
        return paused;
    }
    
    // ============ Admin Functions (No-Op) ============
    
    function setMinimumStake(uint8 tier, uint256 minimum) external override onlyRole(ROLE_ADMIN) {
        uint256 oldMinimum = _dummyMinimumStakes[tier];
        _dummyMinimumStakes[tier] = minimum;
        emit MinimumStakeUpdated(tier, oldMinimum, minimum);
    }
    
    function setUnstakePeriod(uint256 period) external override onlyRole(ROLE_ADMIN) {
        uint256 oldPeriod = _dummyUnstakePeriod;
        _dummyUnstakePeriod = period;
        emit UnstakePeriodUpdated(oldPeriod, period);
    }
    
    function pause(string memory reason) external override onlyRole(ROLE_ADMIN) {
        paused = true;
        emit EmergencyPaused(msg.sender, reason);
    }
    
    function unpause() external override onlyRole(ROLE_ADMIN) {
        paused = false;
        emit EmergencyUnpaused(msg.sender);
    }
    
    // ============ Setup Functions ============
    
    function setResolutionModule(address module) external onlyRole(ROLE_ADMIN) {
        _grantRole(ROLE_RESOLUTION_MODULE, module);
    }
    
    function setStakeToken(address token) external onlyRole(ROLE_ADMIN) {
        address oldToken = _dummyStakeToken;
        _dummyStakeToken = token;
        emit StakeTokenUpdated(oldToken, token);
    }
}
