// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

interface IBondLedger {
    enum BondStatus { NONE, PENDING, SETTLED, FORFEITED }
    /// @dev Kept only as an opaque classification for legacy consumers. Custody
    ///      does not infer allocations from this value.
    enum SettlementKind { REFUND, RESOLVER_PAYOUT, FORFEIT }
    enum DispositionCauseType { RULING_OUTCOME, EXPLICIT_FORFEIT, DISPUTE_FINALIZED }

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

    /// @notice Immutable security-position lineage recorded alongside a bond.
    /// @dev `payer` in BondPosition is the economic owner/refund beneficiary.
    ///      `operator` is the account that initiated the secured action.
    struct PositionRoles {
        address funder;
        address operator;
        address beneficiary;
    }

    struct Allocation {
        address recipient;
        uint256 amount;
    }

    event BondPosted(bytes32 indexed bondId, address indexed application,
                     address indexed payer, address funder, address asset,
                     uint256 principal, bytes32 contextId, bytes32 termsHash);
    event BondSettled(bytes32 indexed bondId, Allocation[] allocations, SettlementKind kind);
    event RealizedDistribution(
        bytes32 indexed bondId,
        bytes32 indexed distributionRoot,
        bytes32 indexed causeRoot,
        DispositionCauseType causeType,
        bytes32 termsHash,
        uint256 principal,
        uint256 allocationCount
    );
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
    function settleBondWithRoot(
        bytes32 bondId,
        Allocation[] calldata allocations,
        SettlementKind kind,
        DispositionCauseType causeType,
        bytes32 causeRoot
    ) external;

    function claim(bytes32 bondId, address recipient) external;

    function claimFor(bytes32 bondId, address recipient) external;

    function getBond(bytes32 bondId) external view returns (BondPosition memory);
    function hasBond(bytes32 bondId) external view returns (bool);
    function getClaimable(bytes32 bondId, address recipient) external view returns (uint256);
    function getSettlementAllocations(bytes32 bondId) external view returns (Allocation[] memory);
    function getPositionRoles(bytes32 bondId) external view returns (PositionRoles memory);
    function getRealizedDistributionRoot(bytes32 bondId) external view returns (bytes32);
    function getAuthoritativeCauseRoot(bytes32 bondId) external view returns (bytes32);
    function getDispositionCauseType(bytes32 bondId) external view returns (DispositionCauseType);
    function realizedDistributionRoot(Allocation[] calldata allocations) external pure returns (bytes32);
}
