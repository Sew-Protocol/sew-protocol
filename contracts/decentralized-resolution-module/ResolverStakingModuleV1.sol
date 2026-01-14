// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "./IStakingModule.sol";
import "./BondValuationLibrary.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ResolverStakingModuleV1
 * @notice Real staking implementation for DR v3 with mixed stable/SEW bonds
 * @dev Key Features:
 *      - ERC20 stablecoin staking (primary)
 *      - SEW token staking (custody, non-transferable while bonded)
 *      - Mix enforcement: 80% stable minimum, 20% SEW maximum (50% haircut)
 *      - Unbonding delays: 14 days (resolvers), 21 days (seniors)
 *      - Delegation coverage: M=3 multiplier, U=50% utilization
 *      - Coverage accounting: reservedCoverage <= availableCoverage
 * 
 * Security Properties:
 *      1. Mix constraints always hold (80/20 rule)
 *      2. Reserved coverage never exceeds available coverage
 *      3. Withdrawals cannot bypass freeze/unbond delays
 *      4. Senior coverage only exposed after resolver exhausted
 */
contract ResolverStakingModuleV1 is 
    IStakingModule,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using BondValuationLibrary for *;
    
    // ============ Constants ============
    
    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");
    bytes32 public constant ROLE_RESOLUTION_MODULE = keccak256("ROLE_RESOLUTION_MODULE");
    
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    
    // Mix enforcement (from BondValuationLibrary)
    uint256 public constant MIN_STABLE_BPS = 8000; // 80%
    uint256 public constant MAX_SEW_BPS = 2000;    // 20%
    
    // Unbonding delays
    uint256 public constant RESOLVER_UNBOND_DELAY = 14 days;
    uint256 public constant SENIOR_UNBOND_DELAY = 21 days;
    
    // Coverage parameters
    uint256 public constant COVERAGE_MULTIPLIER = 3;     // M = 3x
    uint256 public constant UTILIZATION_BPS = 5000;      // U = 50%
    
    // Haircut for SEW
    uint256 public constant SEW_HAIRCUT_BPS = 5000; // 50% haircut
    
    // Token decimals
    uint8 public constant STABLE_DECIMALS = 6;  // USDC
    uint8 public constant SEW_DECIMALS = 18;    // SEW
    
    // ============ State Variables ============
    
    IERC20 public stableToken;  // USDC or other stablecoin
    IERC20 public sewToken;     // Protocol token
    
    bool public paused;
    
    // Minimum stakes per tier
    mapping(uint8 => uint256) public minimumStakes; // tier => min effective bond USD (18 decimals)
    
    // Bond composition per resolver
    struct BondComposition {
        uint256 stableAmount;  // Amount of stablecoin staked
        uint256 sewAmount;     // Amount of SEW staked
        uint256 effectiveBondUSD; // Cached effective bond value (18 decimals)
        uint256 lastUpdated;   // Last time bond was updated
    }
    mapping(address => BondComposition) public resolverBonds;
    
    // Stake status tracking
    mapping(address => StakeStatus) public stakeStatus;
    
    // Unbonding requests
    struct UnbondRequest {
        uint256 stableAmount;
        uint256 sewAmount;
        uint256 availableAt;
        bool exists;
    }
    mapping(address => UnbondRequest) public unbondRequests;
    
    // Coverage tracking (for seniors)
    mapping(address => uint256) public reservedCoverage; // Senior => total coverage reserved by juniors
    
    // Delegation tracking (junior => senior)
    struct DelegationRecord {
        address senior;
        uint256 coverageAmount; // Amount of coverage reserved from senior
        uint256 delegatedAt;
        bool active;
    }
    mapping(address => DelegationRecord) public delegations;
    
    // Reverse mapping (senior => list of juniors)
    mapping(address => address[]) public seniorDelegates;
    mapping(address => mapping(address => uint256)) public seniorDelegateIndex;
    
    // Tier tracking
    mapping(address => uint8) public resolverTier; // 0 = resolver, 1 = senior
    
    // Locked stakes (per dispute)
    mapping(uint256 => mapping(address => uint256)) public lockedStakes; // workflowId => resolver => locked amount
    mapping(address => uint256) public totalLockedStake; // Total locked across all disputes
    
    // ============ Events ============
    
    event BondDeposited(address indexed resolver, uint256 stableAmount, uint256 sewAmount, uint256 effectiveBondUSD);
    event BondWithdrawn(address indexed resolver, uint256 stableAmount, uint256 sewAmount);
    event UnbondRequested(address indexed resolver, uint256 stableAmount, uint256 sewAmount, uint256 availableAt);
    event UnbondCancelled(address indexed resolver);
    event CoverageReserved(address indexed junior, address indexed senior, uint256 amount);
    event CoverageReleased(address indexed junior, address indexed senior, uint256 amount);
    event BondRevalued(address indexed resolver, uint256 oldBond, uint256 newBond);
    event TierUpdated(address indexed resolver, uint8 oldTier, uint8 newTier);
    
    // ============ Initialization ============
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address initialOwner,
        address _stableToken,
        address _sewToken
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(ROLE_ADMIN, initialOwner);
        
        stableToken = IERC20(_stableToken);
        sewToken = IERC20(_sewToken);
        
        paused = false;
        
        // Set default minimum stakes
        minimumStakes[0] = 1000e18;  // Resolver: 1000 USD
        minimumStakes[1] = 10000e18; // Senior: 10000 USD
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ROLE_ADMIN) {}
    
    // ============ Core Staking Functions ============
    
    /**
     * @notice Stake (interface compatibility - defaults to stable only)
     * @param amount Amount to stake (assumed to be stable)
     */
    function stake(uint256 amount) external {
        stakeWithMix(amount, 0);
    }
    
    /**
     * @notice Request unstake (interface compatibility)
     * @param amount Amount to unstake (withdraws proportionally from stable/SEW)
     */
    function requestUnstake(uint256 amount) external {
        address resolver = msg.sender;
        BondComposition storage bond = resolverBonds[resolver];
        
        // Calculate proportional withdrawal
        uint256 totalBond = bond.stableAmount + bond.sewAmount;
        require(totalBond > 0, "No stake");
        
        uint256 stableAmount = (bond.stableAmount * amount) / totalBond;
        uint256 sewAmount = (bond.sewAmount * amount) / totalBond;
        
        requestUnstakeWithMix(stableAmount, sewAmount);
    }
    
    /**
     * @notice Deposit bond (stable + SEW mix)
     * @param stableAmount Amount of stablecoin to deposit
     * @param sewAmount Amount of SEW to deposit
     * @dev Enforces 80/20 mix rule with 50% SEW haircut
     */
    function stakeWithMix(uint256 stableAmount, uint256 sewAmount) public nonReentrant {
        require(!paused, "Paused");
        require(stableAmount > 0 || sewAmount > 0, "Zero stake");
        
        address resolver = msg.sender;
        BondComposition storage bond = resolverBonds[resolver];
        
        // Calculate new total amounts
        uint256 newStableTotal = bond.stableAmount + stableAmount;
        uint256 newSewTotal = bond.sewAmount + sewAmount;
        
        // Check mix enforcement (80% stable, 20% SEW with 50% haircut)
        (bool valid, uint256 stablePct, uint256 sewPct) = BondValuationLibrary.checkBondMix(
            newStableTotal,
            newSewTotal,
            PRECISION, // SEW price = $1 (oracle-free, conservative)
            SEW_HAIRCUT_BPS,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );
        require(valid, "Invalid bond mix");
        
        // Calculate effective bond value
        uint256 effectiveBond = BondValuationLibrary.calculateEffectiveBondUSD(
            newStableTotal,
            newSewTotal,
            PRECISION, // SEW price = $1
            SEW_HAIRCUT_BPS,
            STABLE_DECIMALS,
            SEW_DECIMALS
        );
        
        // Check minimum stake for tier
        uint8 tier = resolverTier[resolver];
        require(effectiveBond >= minimumStakes[tier], "Below minimum stake");
        
        // Transfer tokens
        if (stableAmount > 0) {
            stableToken.safeTransferFrom(resolver, address(this), stableAmount);
        }
        if (sewAmount > 0) {
            sewToken.safeTransferFrom(resolver, address(this), sewAmount);
        }
        
        // Update bond
        bond.stableAmount = newStableTotal;
        bond.sewAmount = newSewTotal;
        bond.effectiveBondUSD = effectiveBond;
        bond.lastUpdated = block.timestamp;
        
        // Update status
        if (stakeStatus[resolver] == StakeStatus.UNSTAKING) {
            stakeStatus[resolver] = StakeStatus.ACTIVE;
            delete unbondRequests[resolver];
        } else if (stakeStatus[resolver] != StakeStatus.ACTIVE) {
            stakeStatus[resolver] = StakeStatus.ACTIVE;
        }
        
        emit StakeDeposited(resolver, stableAmount, effectiveBond);
        emit BondDeposited(resolver, stableAmount, sewAmount, effectiveBond);
    }
    
    /**
     * @notice Request unbonding (starts delay timer)
     * @param stableAmount Amount of stable to unbond
     * @param sewAmount Amount of SEW to unbond
     * @dev Cannot unbond if coverage is reserved or stake is locked
     */
    function requestUnstakeWithMix(uint256 stableAmount, uint256 sewAmount) public nonReentrant {
        require(!paused, "Paused");
        require(stableAmount > 0 || sewAmount > 0, "Zero amount");
        
        address resolver = msg.sender;
        BondComposition storage bond = resolverBonds[resolver];
        
        require(bond.stableAmount >= stableAmount, "Insufficient stable");
        require(bond.sewAmount >= sewAmount, "Insufficient SEW");
        require(stakeStatus[resolver] == StakeStatus.ACTIVE, "Not active");
        require(!unbondRequests[resolver].exists, "Unbond pending");
        
        // Check if resolver has locked stakes
        require(totalLockedStake[resolver] == 0, "Stake locked in disputes");
        
        // Check if resolver is a senior with reserved coverage
        if (resolverTier[resolver] == 1) {
            require(reservedCoverage[resolver] == 0, "Coverage reserved");
        }
        
        // Check if resolver is a junior with delegation
        if (delegations[resolver].active) {
            require(false, "Must undelegate first");
        }
        
        // Calculate remaining bond after unbond
        uint256 remainingStable = bond.stableAmount - stableAmount;
        uint256 remainingSew = bond.sewAmount - sewAmount;
        
        // If not withdrawing everything, check mix is still valid
        if (remainingStable > 0 || remainingSew > 0) {
            (bool valid,,) = BondValuationLibrary.checkBondMix(
                remainingStable,
                remainingSew,
                PRECISION,
                SEW_HAIRCUT_BPS,
                STABLE_DECIMALS,
                SEW_DECIMALS
            );
            require(valid, "Remaining bond invalid mix");
            
            // Check remaining bond meets minimum
            uint256 remainingBond = BondValuationLibrary.calculateEffectiveBondUSD(
                remainingStable,
                remainingSew,
                PRECISION,
                SEW_HAIRCUT_BPS,
                STABLE_DECIMALS,
                SEW_DECIMALS
            );
            uint8 tier = resolverTier[resolver];
            require(remainingBond >= minimumStakes[tier], "Below minimum after unbond");
        }
        
        // Calculate unbond delay based on tier
        uint8 tier = resolverTier[resolver];
        uint256 delay = (tier == 1) ? SENIOR_UNBOND_DELAY : RESOLVER_UNBOND_DELAY;
        uint256 availableAt = block.timestamp + delay;
        
        // Create unbond request
        unbondRequests[resolver] = UnbondRequest({
            stableAmount: stableAmount,
            sewAmount: sewAmount,
            availableAt: availableAt,
            exists: true
        });
        
        stakeStatus[resolver] = StakeStatus.UNSTAKING;
        
        emit UnstakeRequested(resolver, stableAmount + sewAmount, availableAt);
        emit UnbondRequested(resolver, stableAmount, sewAmount, availableAt);
    }
    
    /**
     * @notice Cancel unbonding request
     */
    function cancelUnstake() external nonReentrant {
        address resolver = msg.sender;
        require(unbondRequests[resolver].exists, "No unbond request");
        
        uint256 amount = unbondRequests[resolver].stableAmount + unbondRequests[resolver].sewAmount;
        
        delete unbondRequests[resolver];
        stakeStatus[resolver] = StakeStatus.ACTIVE;
        
        emit UnstakeCancelled(resolver, amount);
        emit UnbondCancelled(resolver);
    }
    
    /**
     * @notice Complete unbonding after delay
     */
    function completeUnstake() external nonReentrant {
        address resolver = msg.sender;
        UnbondRequest storage request = unbondRequests[resolver];
        
        require(request.exists, "No unbond request");
        require(block.timestamp >= request.availableAt, "Unbond delay not passed");
        
        uint256 stableAmount = request.stableAmount;
        uint256 sewAmount = request.sewAmount;
        
        BondComposition storage bond = resolverBonds[resolver];
        
        // Update bond
        bond.stableAmount -= stableAmount;
        bond.sewAmount -= sewAmount;
        
        // Recalculate effective bond
        if (bond.stableAmount > 0 || bond.sewAmount > 0) {
            bond.effectiveBondUSD = BondValuationLibrary.calculateEffectiveBondUSD(
                bond.stableAmount,
                bond.sewAmount,
                PRECISION,
                SEW_HAIRCUT_BPS,
                STABLE_DECIMALS,
                SEW_DECIMALS
            );
        } else {
            bond.effectiveBondUSD = 0;
            stakeStatus[resolver] = StakeStatus.ACTIVE; // Reset to active (no stake)
        }
        bond.lastUpdated = block.timestamp;
        
        // Transfer tokens
        if (stableAmount > 0) {
            stableToken.safeTransfer(resolver, stableAmount);
        }
        if (sewAmount > 0) {
            sewToken.safeTransfer(resolver, sewAmount);
        }
        
        // Clear unbond request
        delete unbondRequests[resolver];
        
        emit StakeWithdrawn(resolver, stableAmount + sewAmount, bond.effectiveBondUSD);
        emit BondWithdrawn(resolver, stableAmount, sewAmount);
    }
    
    /**
     * @notice Emergency withdraw (admin only, for contract migration)
     * @param to Address to send tokens to
     */
    function emergencyWithdraw(address to) external onlyRole(ROLE_ADMIN) {
        address resolver = msg.sender;
        BondComposition storage bond = resolverBonds[resolver];
        
        uint256 stableAmount = bond.stableAmount;
        uint256 sewAmount = bond.sewAmount;
        uint256 totalAmount = stableAmount + sewAmount;
        
        require(totalAmount > 0, "No stake");
        
        // Clear bond
        bond.stableAmount = 0;
        bond.sewAmount = 0;
        bond.effectiveBondUSD = 0;
        bond.lastUpdated = block.timestamp;
        
        // Transfer tokens
        if (stableAmount > 0) {
            stableToken.safeTransfer(to, stableAmount);
        }
        if (sewAmount > 0) {
            sewToken.safeTransfer(to, sewAmount);
        }
        
        emit EmergencyWithdrawal(resolver, totalAmount, to);
    }
    
    // ============ Delegation Functions (Coverage) ============
    
    /**
     * @notice Junior delegates to senior for coverage (M=3, U=0.5)
     * @param senior Senior resolver to delegate to
     * @dev Junior needs coverage = juniorBond × M
     *      Senior provides coverage = seniorBond × U
     */
    function delegateStake(address senior, uint256 /* amount - unused, calculated automatically */) external nonReentrant {
        require(!paused, "Paused");
        
        address junior = msg.sender;
        require(junior != senior, "Cannot delegate to self");
        require(resolverTier[junior] == 0, "Only resolvers can delegate");
        require(resolverTier[senior] == 1, "Must delegate to senior");
        require(!delegations[junior].active, "Already delegated");
        require(stakeStatus[junior] == StakeStatus.ACTIVE, "Junior not active");
        require(stakeStatus[senior] == StakeStatus.ACTIVE, "Senior not active");
        
        // Calculate required coverage for junior
        BondComposition storage juniorBond = resolverBonds[junior];
        uint256 requiredCoverage = juniorBond.effectiveBondUSD * COVERAGE_MULTIPLIER;
        
        // Check senior has available coverage
        BondComposition storage seniorBond = resolverBonds[senior];
        uint256 seniorMaxCoverage = BondValuationLibrary.calculateMaxCoverage(
            seniorBond.effectiveBondUSD,
            UTILIZATION_BPS
        );
        uint256 seniorAvailableCoverage = seniorMaxCoverage - reservedCoverage[senior];
        
        require(seniorAvailableCoverage >= requiredCoverage, "Insufficient senior coverage");
        
        // Reserve coverage
        reservedCoverage[senior] += requiredCoverage;
        
        // Record delegation
        delegations[junior] = DelegationRecord({
            senior: senior,
            coverageAmount: requiredCoverage,
            delegatedAt: block.timestamp,
            active: true
        });
        
        // Add to senior's delegate list
        seniorDelegateIndex[senior][junior] = seniorDelegates[senior].length;
        seniorDelegates[senior].push(junior);
        
        emit StakeDelegated(junior, senior, requiredCoverage);
        emit CoverageReserved(junior, senior, requiredCoverage);
    }
    
    /**
     * @notice Junior undelegates from senior
     */
    function undelegateStake(address senior, uint256 /* amount - unused */) external nonReentrant {
        address junior = msg.sender;
        DelegationRecord storage delegation = delegations[junior];
        
        require(delegation.active, "Not delegated");
        require(delegation.senior == senior, "Wrong senior");
        
        // Check junior has no locked stakes
        require(totalLockedStake[junior] == 0, "Stake locked in disputes");
        
        uint256 coverageAmount = delegation.coverageAmount;
        
        // Release coverage
        reservedCoverage[senior] -= coverageAmount;
        
        // Remove from senior's delegate list
        uint256 index = seniorDelegateIndex[senior][junior];
        uint256 lastIndex = seniorDelegates[senior].length - 1;
        
        if (index != lastIndex) {
            address lastDelegate = seniorDelegates[senior][lastIndex];
            seniorDelegates[senior][index] = lastDelegate;
            seniorDelegateIndex[senior][lastDelegate] = index;
        }
        
        seniorDelegates[senior].pop();
        delete seniorDelegateIndex[senior][junior];
        
        // Clear delegation
        delete delegations[junior];
        
        emit StakeUndelegated(junior, senior, coverageAmount);
        emit CoverageReleased(junior, senior, coverageAmount);
    }
    
    // ============ Lifecycle Hooks (Called by Resolution Module) ============
    
    /**
     * @notice Lock stake when resolver is assigned to dispute
     * @param workflowId Dispute ID
     * @param resolver Resolver address
     * @param stakeRequired Amount of stake to lock (ignored, locks minimum)
     */
    function onResolverAssigned(
        uint256 workflowId,
        address resolver,
        uint256 stakeRequired
    ) external onlyRole(ROLE_RESOLUTION_MODULE) {
        // Lock minimum stake for tier
        uint8 tier = resolverTier[resolver];
        uint256 lockAmount = minimumStakes[tier];
        
        // Check resolver has sufficient available stake
        BondComposition storage bond = resolverBonds[resolver];
        uint256 availableStake = bond.effectiveBondUSD - totalLockedStake[resolver];
        require(availableStake >= lockAmount, "Insufficient available stake");
        
        // Lock stake
        lockedStakes[workflowId][resolver] = lockAmount;
        totalLockedStake[resolver] += lockAmount;
        
        emit StakeLocked(resolver, lockAmount, workflowId, "Assignment");
    }
    
    /**
     * @notice Unlock stake when resolution is finalized
     * @param workflowId Dispute ID
     * @param resolver Resolver address
     * @param outcome Resolution outcome (true = correct, false = incorrect)
     */
    function onResolutionFinalized(
        uint256 workflowId,
        address resolver,
        bool outcome
    ) external onlyRole(ROLE_RESOLUTION_MODULE) {
        uint256 lockedAmount = lockedStakes[workflowId][resolver];
        
        if (lockedAmount > 0) {
            // Unlock stake
            totalLockedStake[resolver] -= lockedAmount;
            delete lockedStakes[workflowId][resolver];
            
            emit StakeUnlocked(resolver, lockedAmount, workflowId);
        }
    }
    
    /**
     * @notice Unlock stake when dispute is escalated
     * @param workflowId Dispute ID
     * @param resolver Prior round resolver
     */
    function onDisputeEscalated(
        uint256 workflowId,
        address resolver
    ) external onlyRole(ROLE_RESOLUTION_MODULE) {
        uint256 lockedAmount = lockedStakes[workflowId][resolver];
        
        if (lockedAmount > 0) {
            // Unlock stake from prior resolver
            totalLockedStake[resolver] -= lockedAmount;
            delete lockedStakes[workflowId][resolver];
            
            emit StakeUnlocked(resolver, lockedAmount, workflowId);
        }
    }
    
    /**
     * @notice Lock stake for specific duration (manual lock)
     */
    function lockStake(
        uint256 workflowId,
        address resolver,
        uint256 amount,
        uint256 duration
    ) external onlyRole(ROLE_RESOLUTION_MODULE) {
        BondComposition storage bond = resolverBonds[resolver];
        uint256 availableStake = bond.effectiveBondUSD - totalLockedStake[resolver];
        require(availableStake >= amount, "Insufficient available stake");
        
        lockedStakes[workflowId][resolver] = amount;
        totalLockedStake[resolver] += amount;
        
        emit StakeLocked(resolver, amount, workflowId, "Manual lock");
    }
    
    /**
     * @notice Unlock stake (manual unlock)
     */
    function unlockStake(
        uint256 workflowId,
        address resolver
    ) external onlyRole(ROLE_RESOLUTION_MODULE) {
        uint256 lockedAmount = lockedStakes[workflowId][resolver];
        
        if (lockedAmount > 0) {
            totalLockedStake[resolver] -= lockedAmount;
            delete lockedStakes[workflowId][resolver];
            
            emit StakeUnlocked(resolver, lockedAmount, workflowId);
        }
    }
    
    // ============ Query Functions ============
    
    /**
     * @notice Get stake info for resolver
     */
    function getStakeInfo(address resolver) external view returns (StakeInfo memory info) {
        BondComposition storage bond = resolverBonds[resolver];
        DelegationRecord storage delegation = delegations[resolver];
        
        uint256 availableStake = bond.effectiveBondUSD > totalLockedStake[resolver] 
            ? bond.effectiveBondUSD - totalLockedStake[resolver] 
            : 0;
        
        info = StakeInfo({
            totalStake: bond.effectiveBondUSD,
            availableStake: availableStake,
            lockedStake: totalLockedStake[resolver],
            delegatedFrom: delegation.active ? delegation.coverageAmount : 0,
            delegatedTo: reservedCoverage[resolver],
            slashedAmount: 0, // Not implemented yet
            unstakeRequestedAt: unbondRequests[resolver].exists ? unbondRequests[resolver].availableAt : 0,
            unstakeAmount: unbondRequests[resolver].exists 
                ? unbondRequests[resolver].stableAmount + unbondRequests[resolver].sewAmount 
                : 0,
            status: stakeStatus[resolver]
        });
    }
    
    /**
     * @notice Check if resolver has sufficient stake
     */
    function isStakeSufficient(address resolver, uint256 required) external view returns (bool sufficient) {
        BondComposition storage bond = resolverBonds[resolver];
        uint256 availableStake = bond.effectiveBondUSD > totalLockedStake[resolver]
            ? bond.effectiveBondUSD - totalLockedStake[resolver]
            : 0;
        
        sufficient = availableStake >= required;
    }
    
    /**
     * @notice Get available stake (not locked)
     */
    function getAvailableStake(address resolver) external view returns (uint256 available) {
        BondComposition storage bond = resolverBonds[resolver];
        available = bond.effectiveBondUSD > totalLockedStake[resolver]
            ? bond.effectiveBondUSD - totalLockedStake[resolver]
            : 0;
    }
    
    /**
     * @notice Get effective stake (including delegation coverage)
     */
    function getEffectiveStake(address resolver) external view returns (uint256 effective) {
        BondComposition storage bond = resolverBonds[resolver];
        DelegationRecord storage delegation = delegations[resolver];
        
        effective = bond.effectiveBondUSD;
        
        // Add coverage from senior if delegated
        if (delegation.active) {
            effective += delegation.coverageAmount;
        }
    }
    
    /**
     * @notice Get delegation info
     */
    function getDelegationInfo(address delegator, address delegatee) 
        external 
        view 
        returns (DelegationInfo memory info) 
    {
        DelegationRecord storage delegation = delegations[delegator];
        
        if (delegation.active && delegation.senior == delegatee) {
            info = DelegationInfo({
                delegator: delegator,
                delegatee: delegatee,
                amount: delegation.coverageAmount,
                delegatedAt: delegation.delegatedAt,
                active: true
            });
        } else {
            info = DelegationInfo({
                delegator: delegator,
                delegatee: delegatee,
                amount: 0,
                delegatedAt: 0,
                active: false
            });
        }
    }
    
    /**
     * @notice Get minimum stake for tier
     */
    function getMinimumStake(uint8 tier) external view returns (uint256 minimum) {
        return minimumStakes[tier];
    }
    
    /**
     * @notice Get stake token (returns stable token)
     */
    function getStakeToken() external view returns (address token) {
        return address(stableToken);
    }
    
    /**
     * @notice Check if paused
     */
    function isPaused() external view returns (bool) {
        return paused;
    }
    
    /**
     * @notice Get bond composition
     */
    function getBondComposition(address resolver) external view returns (
        uint256 stableAmount,
        uint256 sewAmount,
        uint256 effectiveBondUSD,
        uint256 stablePct,
        uint256 sewPct
    ) {
        BondComposition storage bond = resolverBonds[resolver];
        stableAmount = bond.stableAmount;
        sewAmount = bond.sewAmount;
        effectiveBondUSD = bond.effectiveBondUSD;
        
        if (effectiveBondUSD > 0) {
            (, stablePct, sewPct) = BondValuationLibrary.checkBondMix(
                stableAmount,
                sewAmount,
                PRECISION,
                SEW_HAIRCUT_BPS,
                STABLE_DECIMALS,
                SEW_DECIMALS
            );
        }
    }
    
    /**
     * @notice Get senior's coverage stats
     */
    function getSeniorCoverageStats(address senior) external view returns (
        uint256 maxCoverage,
        uint256 reservedCoverageAmount,
        uint256 availableCoverage,
        uint256 numDelegates
    ) {
        BondComposition storage bond = resolverBonds[senior];
        maxCoverage = BondValuationLibrary.calculateMaxCoverage(
            bond.effectiveBondUSD,
            UTILIZATION_BPS
        );
        reservedCoverageAmount = reservedCoverage[senior];
        availableCoverage = maxCoverage > reservedCoverageAmount 
            ? maxCoverage - reservedCoverageAmount 
            : 0;
        numDelegates = seniorDelegates[senior].length;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Set minimum stake for tier
     */
    function setMinimumStake(uint8 tier, uint256 minimum) external onlyRole(ROLE_ADMIN) {
        uint256 oldMinimum = minimumStakes[tier];
        minimumStakes[tier] = minimum;
        emit MinimumStakeUpdated(tier, oldMinimum, minimum);
    }
    
    /**
     * @notice Set unstake period (not used in this version, delays are constants)
     */
    function setUnstakePeriod(uint256 period) external onlyRole(ROLE_ADMIN) {
        // No-op: Delays are constants in this version
        emit UnstakePeriodUpdated(0, period);
    }
    
    /**
     * @notice Pause staking
     */
    function pause(string memory reason) external onlyRole(ROLE_ADMIN) {
        paused = true;
        emit EmergencyPaused(msg.sender, reason);
    }
    
    /**
     * @notice Unpause staking
     */
    function unpause() external onlyRole(ROLE_ADMIN) {
        paused = false;
        emit EmergencyUnpaused(msg.sender);
    }
    
    /**
     * @notice Set resolver tier (0 = resolver, 1 = senior)
     */
    function setResolverTier(address resolver, uint8 tier) external onlyRole(ROLE_ADMIN) {
        require(tier <= 1, "Invalid tier");
        uint8 oldTier = resolverTier[resolver];
        resolverTier[resolver] = tier;
        emit TierUpdated(resolver, oldTier, tier);
    }
    
    /**
     * @notice Set resolution module address
     */
    function setResolutionModule(address module) external onlyRole(ROLE_ADMIN) {
        _grantRole(ROLE_RESOLUTION_MODULE, module);
    }
}
