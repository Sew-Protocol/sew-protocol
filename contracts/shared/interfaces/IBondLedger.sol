// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

interface IBondLedger {
    enum BondStatus { NONE, PENDING, SETTLED, FORFEITED }
    enum SettlementKind { REFUND, RESOLVER_PAYOUT, FORFEIT }

    struct BondPosition {
        address application;
        address payer;
        address funder;
        address asset;
        uint256 principal;
        bytes32 contextId;
        bytes32 termsHash;
        uint8 status;
        uint8 allocationCount;
    }

    struct Allocation {
        address recipient;
        uint256 amount;
    }

    event BondPosted(bytes32 indexed bondId, address indexed application,
                     address indexed payer, address funder, address asset,
                     uint256 principal, bytes32 contextId, bytes32 termsHash);
    event BondSettled(bytes32 indexed bondId, Allocation[] allocations, SettlementKind kind);
    event ClaimProcessed(bytes32 indexed bondId, address indexed recipient,
                         uint256 amount, address asset);

    function postBond(
        bytes32 bondId,
        address application,
        address payer,
        address funder,
        address asset,
        uint256 principal,
        bytes32 contextId,
        bytes32 termsHash
    ) external payable;

    function settleBond(bytes32 bondId, Allocation[] calldata allocations, SettlementKind kind) external;

    function claim(bytes32 bondId, address recipient) external;

    function claimFor(bytes32 bondId, address recipient) external;

    function getBond(bytes32 bondId) external view returns (BondPosition memory);
    function hasBond(bytes32 bondId) external view returns (bool);
    function getClaimable(bytes32 bondId, address recipient) external view returns (uint256);
    function getSettlementAllocations(bytes32 bondId) external view returns (Allocation[] memory);
}
