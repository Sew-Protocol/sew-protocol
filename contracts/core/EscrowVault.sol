// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BaseEscrow.sol";
import "../governance/SlowLaneQueueActivate.sol";
import "../libraries/RecoveryLibrary.sol";
import "../interfaces/IReleaseStrategy.sol";
import "../shared/interfaces/IResolutionModule.sol";
import "../interfaces/IYieldGenerationModule.sol";
import "../interfaces/IYieldDistributionModule.sol";

contract EscrowVault is BaseEscrow {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public totalFeesPerToken;
    mapping(address => uint256) public totalHeldInEscrowPerToken;
    
    IReleaseStrategy public defaultReleaseStrategy;
    IYieldGenerationModule public defaultYieldGenerationModule;
    IYieldDistributionModule public defaultYieldDistributionModule;

    PendingAddress private _pRel;
    PendingAddress private _pYG;
    PendingAddress private _pYD;

    event EscrowTransferCreated(uint256 indexed workflowId, address indexed token, address indexed from, address to, uint256 amount);
    event EscrowTransferReleased(uint256 indexed workflowId, address indexed token, address indexed to, uint256 amount);
    event EscrowTransferCancelled(uint256 indexed workflowId, address indexed token, address indexed from, uint256 amount);
    event FeesWithdrawn(address indexed token, uint256 amount);

    constructor(uint256 f, address fa, address y, address d) SlowLaneQueueActivate() {
        escrowFee = f; escrowFeeAddress = fa; yieldOps = YieldOps(y); disputeOps = DisputeOps(d);
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function createEscrow(address token, address seller, uint256 amount, uint256 autoReleaseTime, uint256 autoCancelTime) public nonReentrant whenNotPaused returns (uint256) {
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

    function _getReleaseStrategy(uint256 id) internal view override returns (IReleaseStrategy) { address s = snapshotReleaseStrategies[id]; return s != address(0) ? IReleaseStrategy(s) : defaultReleaseStrategy; }
    function _getResolutionModule(uint256 id) internal view override returns (IResolutionModule) { 
        address s = snapshotResolutionModules[id]; 
        if (s != address(0)) {
            return IResolutionModule(s);
        }
        // Use BaseEscrow's disputeResolutionModule
        return IResolutionModule(disputeResolutionModule);
    }
    function _getYieldGenerationModule(uint256 id) internal view override returns (IYieldGenerationModule) { address s = snapshotYieldGenerationModules[id]; return s != address(0) ? IYieldGenerationModule(s) : defaultYieldGenerationModule; }
    function _getYieldDistributionModule(uint256 id) internal view override returns (IYieldDistributionModule) { address s = snapshotYieldDistributionModules[id]; return s != address(0) ? IYieldDistributionModule(s) : defaultYieldDistributionModule; }

    function getReleaseStrategy(uint256) public view returns (IReleaseStrategy) { return defaultReleaseStrategy; }
    function getResolutionModule(uint256) public view returns (IResolutionModule) { return IResolutionModule(disputeResolutionModule); }
    function getYieldGenerationModule(uint256) public view returns (IYieldGenerationModule) { return defaultYieldGenerationModule; }
    function getYieldDistributionModule(uint256) public view returns (IYieldDistributionModule) { return defaultYieldDistributionModule; }

    function queueDefaultReleaseStrategy(address s) public onlyRole(ROLE_TIMELOCK) { _queueAddress(_pRel, s); }
    function activateDefaultReleaseStrategy() public onlyRole(ROLE_TIMELOCK) { defaultReleaseStrategy = IReleaseStrategy(_activateAddress(_pRel)); }
    function queueDefaultYieldGenerationModule(address m) public onlyRole(ROLE_TIMELOCK) { _queueAddress(_pYG, m); }
    function activateDefaultYieldGenerationModule() public onlyRole(ROLE_TIMELOCK) { defaultYieldGenerationModule = IYieldGenerationModule(_activateAddress(_pYG)); }
    function queueDefaultYieldDistributionModule(address m) public onlyRole(ROLE_TIMELOCK) { _queueAddress(_pYD, m); }
    function activateDefaultYieldDistributionModule() public onlyRole(ROLE_TIMELOCK) { defaultYieldDistributionModule = IYieldDistributionModule(_activateAddress(_pYD)); }

    function getPendingDefaultReleaseStrategy() public view returns (address, uint64, bool) { return getPendingAddress(_pRel); }
    function getPendingDefaultYieldGenerationModule() public view returns (address, uint64, bool) { return getPendingAddress(_pYG); }
    function getPendingDefaultYieldDistributionModule() public view returns (address, uint64, bool) { return getPendingAddress(_pYD); }

    function withdrawFees(address t) public nonReentrant returns (bool) {
        if (_msgSender() != escrowFeeAddress) revert NotFeeAddress(_msgSender(), escrowFeeAddress);
        uint256 f = totalFeesPerToken[t]; if (f == 0) revert NoFeesToWithdraw(t, f);
        totalFeesPerToken[t] = 0; totalFees -= f;
        IERC20(t).safeTransfer(escrowFeeAddress, f); emit FeesWithdrawn(t, f); return true;
    }

    function recoverERC20(address t, address r, uint256 a) external override onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        uint256 bal = IERC20(t).balanceOf(address(this)); uint256 esc = totalHeldInEscrowPerToken[t]; uint256 fee = totalFeesPerToken[t];
        uint256 rec = a == 0 ? (bal > esc + fee ? bal - esc - fee : 0) : a;
        rec = RecoveryLibrary.recoverERC20(t, r, rec, bal); emit ERC20Recovered(t, r, rec); return true;
    }
}