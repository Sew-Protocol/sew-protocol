// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import './BaseEscrow.sol';
import '../types/EscrowTypes.sol';

/**
 * @title EscrowableERC20
 * @notice Placeholder to unblock build for EscrowVault optimization
 */
contract EscrowableERC20 is ERC20, BaseEscrow {
    constructor(
        string memory n,
        string memory s,
        uint256 f,
        address fa,
        address y,
        address d
    ) ERC20(n, s) {
        if (fa == address(0)) revert InvalidAddress('Fee address cannot be zero', fa);
        if (y == address(0)) revert InvalidAddress('YieldOps address cannot be zero', y);
        if (d == address(0)) revert InvalidAddress('DisputeOps address cannot be zero', d);

        escrowFee = f;
        escrowFeeAddress = fa;
        yieldOps = YieldOps(y);
        disputeOps = DisputeOps(d);
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ROLE_TIMELOCK, _msgSender());

        // Initialize protocol fees
        yieldProtocolFeeBps = 3000; // 30% default
        appealBondProtocolFeeBps = 0; // 0% default

        // Initialize timeout config
        timeoutConfig = TimeoutConfig({
            defaultAutoReleaseTime: 0,
            defaultAutoCancelTime: 0,
            maxDisputeDuration: 90 days,
            appealWindowDuration: 2 days
        });
    }
    function _pullTokens(address t, address f, uint256 a) internal override {}
    function _recordFee(address t, uint256 a) internal override {}
    function _depositForYield(
        IYieldGenerationModule g,
        uint256 w,
        address t,
        uint256 a
    ) internal override {}
    function _emitEscrowTransferCreated(
        uint256 w,
        address t,
        address f,
        address to,
        uint256 a
    ) internal override {}
    function _transferTokens(address t, address to, uint256 a) internal override {}
    function _updateEscrowBalance(address t, uint256 a, bool add) internal override {}
    function _emitEscrowTransferCancelled(
        uint256 w,
        address t,
        address f,
        uint256 a
    ) internal override {}
    function _emitEscrowTransferReleased(
        uint256 w,
        address t,
        address to,
        uint256 a
    ) internal override {}
    function _getYieldGenerationModule(
        uint256 id
    ) internal view override returns (IYieldGenerationModule) {
        return IYieldGenerationModule(address(0));
    }
    function _getYieldDistributionModule(
        uint256 id
    ) internal view override returns (IYieldDistributionModule) {
        return IYieldDistributionModule(address(0));
    }
    function _getReleaseStrategy(uint256 id) internal view override returns (IReleaseStrategy) {
        return IReleaseStrategy(address(0));
    }
    function _getResolutionModule(uint256 id) internal view override returns (IResolutionModule) {
        return super._getResolutionModule(id);
    }

    function getReleaseStrategy(uint256) public view returns (IReleaseStrategy) {
        return _getReleaseStrategy(0);
    }
    function getResolutionModule(uint256) public view returns (IResolutionModule) {
        return _getResolutionModule(0);
    }
    function getYieldGenerationModule(uint256) public view returns (IYieldGenerationModule) {
        return _getYieldGenerationModule(0);
    }
    function getYieldDistributionModule(uint256) public view returns (IYieldDistributionModule) {
        return _getYieldDistributionModule(0);
    }
    function getPendingDefaultResolutionModule() public view returns (address, uint64, bool) {
        return (address(0), 0, false);
    }
    function queueEscrowFee(uint256) public override {}
    function activateEscrowFee() public override {}
    function getPendingEscrowFee() public view override returns (uint256, uint64, bool) {
        return (0, 0, false);
    }
}

contract EscrowableERC20Factory {
    function createEscrowableERC20(
        string memory n,
        string memory s,
        uint256 f,
        address fa,
        address y,
        address d
    ) public returns (address) {
        return address(new EscrowableERC20(n, s, f, fa, y, d));
    }
}
