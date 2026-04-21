// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '../../governance/SlowLaneQueueActivate.sol';
import './IBondTokenRegistry.sol';

/**
 * @title BondTokenRegistry
 * @notice Standalone registry for accepted bond tokens used in decentralized resolution appeals.
 * @dev Extracted from DecentralizedResolutionModule to reduce bytecode size.
 *      All governance operations use the slow-lane queue/activate pattern (7-day delay).
 *      DecentralizedResolutionModule holds a reference to this contract via IBondTokenRegistry.
 */
contract BondTokenRegistry is SlowLaneQueueActivate, AccessControl, IBondTokenRegistry {
    error InvalidBondToken(address token);
    error TokenAlreadyInWhitelist(address token);
    error CannotRemoveDefaultToken(address token);
    error TokenNotInWhitelist(address token);
    error NoPendingBondTokenChange();
    error PendingChangeExists();
    error TimelockNotElapsed(uint64 eta, uint256 current);

    event AcceptedBondTokenQueued(address indexed token, bool isAdd, uint64 eta);
    event AcceptedBondTokenChanged(address indexed token, bool isAdd);
    event DefaultBondTokenQueued(address indexed token, uint64 eta);
    event DefaultBondTokenChanged(address indexed oldToken, address indexed newToken);

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    struct PendingBondTokenChange {
        address token;
        bool isAdd;
        uint64 eta;
        bool exists;
    }

    struct PendingDefaultBondToken {
        address token;
        uint64 eta;
        bool exists;
    }

    mapping(address => bool) public acceptedBondTokens;
    address[] public acceptedBondTokensList;
    address public override defaultBondToken;

    // Index tracking for O(1) swap-and-pop removal
    mapping(address => uint256) private _bondTokenIndex;

    PendingBondTokenChange private _pendingBondTokenChange;
    PendingDefaultBondToken private _pendingDefaultBondToken;

    constructor(address timelockAdmin, address initialDefaultToken) {
        _grantRole(DEFAULT_ADMIN_ROLE, timelockAdmin);
        _grantRole(ROLE_TIMELOCK, timelockAdmin);

        _bondTokenIndex[initialDefaultToken] = acceptedBondTokensList.length;
        acceptedBondTokens[initialDefaultToken] = true;
        acceptedBondTokensList.push(initialDefaultToken);
        defaultBondToken = initialDefaultToken;
    }

    // ============ IBondTokenRegistry ============

    function isAccepted(address token) external view override returns (bool) {
        return acceptedBondTokens[token];
    }

    // ============ Governance ============

    function queueAddAcceptedBondToken(address token) external onlyRole(ROLE_TIMELOCK) {
        if (_pendingBondTokenChange.exists) revert PendingChangeExists();
        if (acceptedBondTokens[token]) revert TokenAlreadyInWhitelist(token);

        _pendingBondTokenChange = PendingBondTokenChange({
            token: token,
            isAdd: true,
            eta: uint64(block.timestamp + SLOW_DELAY),
            exists: true
        });

        emit AcceptedBondTokenQueued(token, true, _pendingBondTokenChange.eta);
    }

    function queueRemoveAcceptedBondToken(address token) external onlyRole(ROLE_TIMELOCK) {
        if (_pendingBondTokenChange.exists) revert PendingChangeExists();
        if (token == defaultBondToken) revert CannotRemoveDefaultToken(token);
        if (!acceptedBondTokens[token]) revert TokenNotInWhitelist(token);

        _pendingBondTokenChange = PendingBondTokenChange({
            token: token,
            isAdd: false,
            eta: uint64(block.timestamp + SLOW_DELAY),
            exists: true
        });

        emit AcceptedBondTokenQueued(token, false, _pendingBondTokenChange.eta);
    }

    function activateBondTokenWhitelistChange() external onlyRole(ROLE_TIMELOCK) {
        if (!_pendingBondTokenChange.exists) revert NoPendingBondTokenChange();
        if (block.timestamp < _pendingBondTokenChange.eta) {
            revert TimelockNotElapsed(_pendingBondTokenChange.eta, block.timestamp);
        }

        address token = _pendingBondTokenChange.token;
        bool isAdd = _pendingBondTokenChange.isAdd;

        if (isAdd) {
            _bondTokenIndex[token] = acceptedBondTokensList.length;
            acceptedBondTokens[token] = true;
            acceptedBondTokensList.push(token);
        } else {
            // Swap-and-pop to keep list compact
            uint256 idx = _bondTokenIndex[token];
            uint256 lastIdx = acceptedBondTokensList.length - 1;
            if (idx != lastIdx) {
                address last = acceptedBondTokensList[lastIdx];
                acceptedBondTokensList[idx] = last;
                _bondTokenIndex[last] = idx;
            }
            acceptedBondTokensList.pop();
            delete _bondTokenIndex[token];
            acceptedBondTokens[token] = false;
        }

        delete _pendingBondTokenChange;
        emit AcceptedBondTokenChanged(token, isAdd);
    }

    function queueSetDefaultBondToken(address token) external onlyRole(ROLE_TIMELOCK) {
        if (!acceptedBondTokens[token]) revert TokenNotInWhitelist(token);

        _pendingDefaultBondToken = PendingDefaultBondToken({
            token: token,
            eta: uint64(block.timestamp + SLOW_DELAY),
            exists: true
        });

        emit DefaultBondTokenQueued(token, _pendingDefaultBondToken.eta);
    }

    function activateDefaultBondToken() external onlyRole(ROLE_TIMELOCK) {
        if (!_pendingDefaultBondToken.exists) revert NoPendingBondTokenChange();
        if (block.timestamp < _pendingDefaultBondToken.eta) {
            revert TimelockNotElapsed(_pendingDefaultBondToken.eta, block.timestamp);
        }

        address oldToken = defaultBondToken;
        address newToken = _pendingDefaultBondToken.token;

        defaultBondToken = newToken;
        delete _pendingDefaultBondToken;

        emit DefaultBondTokenChanged(oldToken, newToken);
    }

    // ============ Views ============

    function getAcceptedBondTokens() external view returns (address[] memory) {
        return acceptedBondTokensList;
    }

    function getPendingBondTokenChange()
        external
        view
        returns (address token, bool isAdd, uint64 eta, bool exists)
    {
        return (
            _pendingBondTokenChange.token,
            _pendingBondTokenChange.isAdd,
            _pendingBondTokenChange.eta,
            _pendingBondTokenChange.exists
        );
    }

    function getPendingDefaultBondToken()
        external
        view
        returns (address token, uint64 eta, bool exists)
    {
        return (
            _pendingDefaultBondToken.token,
            _pendingDefaultBondToken.eta,
            _pendingDefaultBondToken.exists
        );
    }
}
