// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BaseEscrow.sol";
import "../governance/SlowLaneQueueActivate.sol";
import "../libraries/RecoveryLibrary.sol";
import "../types/EscrowTypes.sol";
import "../interfaces/IReleaseStrategy.sol";
import "../shared/interfaces/IResolutionModule.sol";
import "../interfaces/IYieldGenerationModule.sol";
import "../interfaces/IYieldDistributionModule.sol";

contract EscrowVault is BaseEscrow {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public totalFeesPerToken;
    // Tracks total amount held in escrow per token (immutable amounts - no partial releases)
    mapping(address => uint256) public totalHeldInEscrowPerToken;
    
    IReleaseStrategy public defaultReleaseStrategy;
    IYieldGenerationModule public defaultYieldGenerationModule;
    IYieldDistributionModule public defaultYieldDistributionModule;

    PendingAddress private _pRel;
    PendingAddress private _pYG;
    PendingAddress private _pYD;

    event EscrowTransferCreated(uint256 indexed escrowId, address indexed token, address indexed from, address to, uint256 amount);
    event EscrowTransferReleased(uint256 indexed escrowId, address indexed token, address indexed to, uint256 amount);
    event EscrowTransferCancelled(uint256 indexed escrowId, address indexed token, address indexed from, uint256 amount);
    event FeesWithdrawn(address indexed token, uint256 amount);

    constructor(uint256 f, address fa, address y, address d) SlowLaneQueueActivate() {
        if (fa == address(0)) revert InvalidAddress("Fee address cannot be zero", fa);
        if (y == address(0)) revert InvalidAddress("YieldOps address cannot be zero", y);
        if (d == address(0)) revert InvalidAddress("DisputeOps address cannot be zero", d);
        
        escrowFee = f; escrowFeeAddress = fa; yieldOps = YieldOps(y); disputeOps = DisputeOps(d);
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        
        // Initialize timeout config
        timeoutConfig = TimeoutConfig({
            defaultAutoReleaseTime: 0,
            defaultAutoCancelTime: 0,
            maxDisputeDuration: 90 days,
            appealWindowDuration: 2 days
        });
    }

    function createEscrow(address token, address seller, uint256 amount, uint256 autoReleaseTime, uint256 autoCancelTime) public whenNotPaused returns (uint256) {
        EscrowSettings memory settings = getDefaultSettings(); settings.autoReleaseTime = autoReleaseTime; settings.autoCancelTime = autoCancelTime;
        return createEscrow(token, seller, amount, settings);
    }

    function createEscrow(address token, address seller, uint256 amount) public whenNotPaused returns (uint256) {
        return createEscrow(token, seller, amount, getDefaultSettings());
    }

    function releaseEscrowTransfer(uint256 id) public nonReentrant whenNotPaused returns (bool) {
        _requirePending(id); if (escrowTransfers[id].from != _msgSender()) revert NotSender(id, _msgSender(), escrowTransfers[id].from);
        _releaseEscrowTransfer(id); return true;
    }

    function _pullTokens(address t, address f, uint256 a) internal override { IERC20(t).safeTransferFrom(f, address(this), a); }
    function _recordFee(address t, uint256 a) internal override { totalFeesPerToken[t] += a; }
    function _depositForYield(IYieldGenerationModule g, uint256 w, address t, uint256 a) internal override { g.depositForYield(w, t, a); }
    function _emitEscrowTransferCreated(uint256 w, address t, address f, address to, uint256 a) internal override { emit EscrowTransferCreated(w, t, f, to, a); }
    function _transferTokens(address t, address to, uint256 a) internal override { IERC20(t).safeTransfer(to, a); }
    function _updateEscrowBalance(address t, uint256 a, bool add) internal override { if (add) totalHeldInEscrowPerToken[t] += a; else totalHeldInEscrowPerToken[t] -= a; }
    function _emitEscrowTransferCancelled(uint256 w, address t, address f, uint256 a) internal override { emit EscrowTransferCancelled(w, t, f, a); }
    function _emitEscrowTransferReleased(uint256 w, address t, address to, uint256 a) internal override { emit EscrowTransferReleased(w, t, to, a); }

    /**
     * @notice Helper function to get module from snapshot or return default (for IReleaseStrategy)
     * @param snapshotAddress Address from snapshot mapping (may be zero)
     * @param defaultModule Default module to return if snapshot is zero
     * @return Module instance (from snapshot if non-zero, otherwise default)
     */
    function _getReleaseStrategyOrDefault(address snapshotAddress, IReleaseStrategy defaultModule) internal pure returns (IReleaseStrategy) {
        return snapshotAddress != address(0) ? IReleaseStrategy(snapshotAddress) : defaultModule;
    }

    /**
     * @notice Helper function to get module from snapshot or return default (for IYieldGenerationModule)
     * @param snapshotAddress Address from snapshot mapping (may be zero)
     * @param defaultModule Default module to return if snapshot is zero
     * @return Module instance (from snapshot if non-zero, otherwise default)
     */
    function _getYieldGenerationModuleOrDefault(address snapshotAddress, IYieldGenerationModule defaultModule) internal pure returns (IYieldGenerationModule) {
        return snapshotAddress != address(0) ? IYieldGenerationModule(snapshotAddress) : defaultModule;
    }

    /**
     * @notice Helper function to get module from snapshot or return default (for IYieldDistributionModule)
     * @param snapshotAddress Address from snapshot mapping (may be zero)
     * @param defaultModule Default module to return if snapshot is zero
     * @return Module instance (from snapshot if non-zero, otherwise default)
     */
    function _getYieldDistributionModuleOrDefault(address snapshotAddress, IYieldDistributionModule defaultModule) internal pure returns (IYieldDistributionModule) {
        return snapshotAddress != address(0) ? IYieldDistributionModule(snapshotAddress) : defaultModule;
    }

    function _getReleaseStrategy(uint256 id) internal view override returns (IReleaseStrategy) {
        return _getReleaseStrategyOrDefault(snapshotReleaseStrategies[id], defaultReleaseStrategy);
    }
    
    function _getResolutionModule(uint256 id) internal view override returns (IResolutionModule) { 
        address s = snapshotResolutionModules[id]; 
        if (s != address(0)) {
            return IResolutionModule(s);
        }
        // Use BaseEscrow's disputeResolutionModule
        return IResolutionModule(disputeResolutionModule);
    }
    
    function _getYieldGenerationModule(uint256 id) internal view override returns (IYieldGenerationModule) {
        return _getYieldGenerationModuleOrDefault(snapshotYieldGenerationModules[id], defaultYieldGenerationModule);
    }
    
    function _getYieldDistributionModule(uint256 id) internal view override returns (IYieldDistributionModule) {
        return _getYieldDistributionModuleOrDefault(snapshotYieldDistributionModules[id], defaultYieldDistributionModule);
    }

    /**
     * @notice Get default release strategy
     * @return Default release strategy
     */
    function getReleaseStrategy(uint256) public view returns (IReleaseStrategy) { return defaultReleaseStrategy; }
    
    /**
     * @notice Get default resolution module
     * @return Default resolution module
     */
    function getResolutionModule(uint256) public view returns (IResolutionModule) { return IResolutionModule(disputeResolutionModule); }
    
    /**
     * @notice Get default yield generation module
     * @return Default yield generation module
     */
    function getYieldGenerationModule(uint256) public view returns (IYieldGenerationModule) { return defaultYieldGenerationModule; }
    
    /**
     * @notice Get default yield distribution module
     * @return Default yield distribution module
     */
    function getYieldDistributionModule(uint256) public view returns (IYieldDistributionModule) { return defaultYieldDistributionModule; }

    /**
     * @notice Queue a new default release strategy
     * @param s Address of the new release strategy to queue
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     */
    function queueDefaultReleaseStrategy(address s) public onlyRole(ROLE_TIMELOCK) { _queueAddress(_pRel, s); }
    
    /**
     * @notice Activate the queued default release strategy
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     */
    function activateDefaultReleaseStrategy() public onlyRole(ROLE_TIMELOCK) { defaultReleaseStrategy = IReleaseStrategy(_activateAddress(_pRel)); }
    
    /**
     * @notice Queue a new default yield generation module
     * @param m Address of the new yield generation module to queue
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     */
    function queueDefaultYieldGenerationModule(address m) public onlyRole(ROLE_TIMELOCK) { _queueAddress(_pYG, m); }
    
    /**
     * @notice Activate the queued default yield generation module
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     */
    function activateDefaultYieldGenerationModule() public onlyRole(ROLE_TIMELOCK) { defaultYieldGenerationModule = IYieldGenerationModule(_activateAddress(_pYG)); }
    
    /**
     * @notice Queue a new default yield distribution module
     * @param m Address of the new yield distribution module to queue
     * @dev Uses slow lane activation pattern. Requires ROLE_TIMELOCK.
     */
    function queueDefaultYieldDistributionModule(address m) public onlyRole(ROLE_TIMELOCK) { _queueAddress(_pYD, m); }
    
    /**
     * @notice Activate the queued default yield distribution module
     * @dev Activates after timelock delay. Requires ROLE_TIMELOCK.
     */
    function activateDefaultYieldDistributionModule() public onlyRole(ROLE_TIMELOCK) { defaultYieldDistributionModule = IYieldDistributionModule(_activateAddress(_pYD)); }

    /**
     * @notice Get pending default release strategy information
     * @return Pending release strategy address, activation timestamp, and existence flag
     */
    function getPendingDefaultReleaseStrategy() public view returns (address, uint64, bool) { return getPendingAddress(_pRel); }
    
    /**
     * @notice Get pending default yield generation module information
     * @return Pending yield generation module address, activation timestamp, and existence flag
     */
    function getPendingDefaultYieldGenerationModule() public view returns (address, uint64, bool) { return getPendingAddress(_pYG); }
    
    /**
     * @notice Get pending default yield distribution module information
     * @return Pending yield distribution module address, activation timestamp, and existence flag
     */
    function getPendingDefaultYieldDistributionModule() public view returns (address, uint64, bool) { return getPendingAddress(_pYD); }

    /**
     * @notice Withdraw accumulated fees for a specific token
     * @param t Token address to withdraw fees for
     * @return success Whether withdrawal succeeded
     * @dev Only fee address can withdraw. Withdraws all accumulated fees for the token.
     */
    function withdrawFees(address t) public nonReentrant returns (bool) {
        if (_msgSender() != escrowFeeAddress) revert NotFeeAddress(_msgSender(), escrowFeeAddress);
        uint256 f = totalFeesPerToken[t]; if (f == 0) revert NoFeesToWithdraw(t, f);
        totalFeesPerToken[t] = 0;
        IERC20(t).safeTransfer(escrowFeeAddress, f); emit FeesWithdrawn(t, f); return true;
    }

    /**
     * @notice Recover ERC20 tokens (excluding escrow balances and fees)
     * @param t Token address to recover
     * @param r Recipient address
     * @param a Amount to recover (0 = recover all excess)
     * @return success Whether recovery succeeded
     * @dev Only recovers tokens beyond escrow balances and fees. Requires ROLE_TIMELOCK.
     */
    function recoverERC20(address t, address r, uint256 a) external override onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        uint256 bal = IERC20(t).balanceOf(address(this)); uint256 esc = totalHeldInEscrowPerToken[t]; uint256 fee = totalFeesPerToken[t];
        uint256 rec = a == 0 ? (bal > esc + fee ? bal - esc - fee : 0) : a;
        rec = RecoveryLibrary.recoverERC20(t, r, rec, bal); emit ERC20Recovered(t, r, rec); return true;
    }
}