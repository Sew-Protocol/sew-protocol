// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './interfaces/IBondLedger.sol';

contract BondLedger is IBondLedger, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant AUTHORIZED_CALLER = keccak256('AUTHORIZED_CALLER');

    uint256 public constant MAX_ALLOCATIONS = 50;

    mapping(bytes32 => BondPosition) private _positions;
    mapping(bytes32 => mapping(address => uint256)) private _claimable;
    mapping(bytes32 => Allocation[]) private _settlementAllocations;
    mapping(address => uint256) public forfeitedBondReserve;

    error NotAuthorized();
    error ZeroAddress();

    modifier onlyAuthorized() {
        if (!hasRole(AUTHORIZED_CALLER, _msgSender())) revert NotAuthorized();
        _;
    }

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROLE_TIMELOCK, admin);
    }

    function addAuthorizedCaller(address caller) external onlyRole(ROLE_TIMELOCK) {
        _grantRole(AUTHORIZED_CALLER, caller);
    }

    function removeAuthorizedCaller(address caller) external onlyRole(ROLE_TIMELOCK) {
        _revokeRole(AUTHORIZED_CALLER, caller);
    }

    function postBond(
        bytes32 bondId,
        address application,
        address payer,
        address funder,
        address asset,
        uint256 principal,
        bytes32 contextId,
        bytes32 termsHash
    ) external payable onlyAuthorized nonReentrant {
        BondPosition storage pos = _positions[bondId];
        if (pos.status != uint8(BondStatus.NONE)) revert InvalidStatus();

        if (asset == address(0)) {
            if (msg.value != principal) revert InvalidAmount();
        } else {
            uint256 balBefore = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(funder, address(this), principal);
            if (IERC20(asset).balanceOf(address(this)) - balBefore != principal) revert InvalidAmount();
        }

        _positions[bondId] = BondPosition({
            application: application,
            payer: payer,
            funder: funder,
            asset: asset,
            principal: principal,
            contextId: contextId,
            termsHash: termsHash,
            status: uint8(BondStatus.PENDING),
            allocationCount: 0
        });

        emit BondPosted(bondId, application, payer, funder, asset, principal, contextId, termsHash);
    }

    function settleBond(
        bytes32 bondId,
        Allocation[] calldata allocations,
        SettlementKind kind
    ) external onlyAuthorized nonReentrant {
        BondPosition storage pos = _positions[bondId];
        if (pos.status != uint8(BondStatus.PENDING)) revert InvalidStatus();

        uint256 len = allocations.length;
        if (len == 0) revert InvalidAllocations();
        if (len > MAX_ALLOCATIONS) revert InvalidAllocations();

        uint256 sum;
        for (uint256 i = 0; i < len; i++) {
            if (allocations[i].recipient == address(0)) revert InvalidAllocations();
            if (allocations[i].amount == 0) revert InvalidAllocations();
            sum += allocations[i].amount;
        }

        if (kind == SettlementKind.FORFEIT) {
            if (len != 1) revert InvalidAllocations();
            forfeitedBondReserve[pos.asset] += sum;
        } else {
            for (uint256 i = 0; i < len; i++) {
                _claimable[bondId][allocations[i].recipient] += allocations[i].amount;
            }
        }

        if (sum != pos.principal) revert InvalidAllocations();

        pos.status = uint8(BondStatus.SETTLED);
        pos.allocationCount = uint8(len);

        Allocation[] storage stored = _settlementAllocations[bondId];
        for (uint256 i = 0; i < len; i++) {
            stored.push(allocations[i]);
        }

        emit BondSettled(bondId, allocations, kind);
    }

    function claim(bytes32 bondId, address recipient) external nonReentrant {
        _claim(bondId, recipient);
    }

    function claimFor(bytes32 bondId, address recipient) external onlyAuthorized nonReentrant {
        _claim(bondId, recipient);
    }

    function _claim(bytes32 bondId, address recipient) internal {
        BondPosition memory pos = _positions[bondId];
        if (pos.status == uint8(BondStatus.NONE)) revert InvalidStatus();

        uint256 amount = _claimable[bondId][recipient];
        if (amount == 0) revert NothingClaimable();
        delete _claimable[bondId][recipient];

        if (pos.asset == address(0)) {
            (bool ok, ) = payable(recipient).call{value: amount}("");
            if (!ok) revert ClaimFailed();
        } else {
            IERC20(pos.asset).safeTransfer(recipient, amount);
        }

        emit ClaimProcessed(bondId, recipient, amount, pos.asset);
    }

    function getBond(bytes32 bondId) external view returns (BondPosition memory) {
        BondPosition memory pos = _positions[bondId];
        if (pos.status == uint8(BondStatus.NONE)) revert InvalidStatus();
        return pos;
    }

    function hasBond(bytes32 bondId) external view returns (bool) {
        return _positions[bondId].status != uint8(BondStatus.NONE);
    }

    function getClaimable(bytes32 bondId, address recipient) external view returns (uint256) {
        return _claimable[bondId][recipient];
    }

    function getSettlementAllocations(bytes32 bondId) external view returns (Allocation[] memory) {
        return _settlementAllocations[bondId];
    }

    // ── errors ──

    error InvalidStatus();
    error InvalidAmount();
    error InvalidAllocations();
    error NothingClaimable();
    error ClaimFailed();
}
