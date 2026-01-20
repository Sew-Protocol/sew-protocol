// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import { IResolver, Payout } from "../interfaces/IResolver.sol";

interface IEscrowResolverActions {
    function cancelAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) external returns (bool);
    function releaseAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) external returns (bool);
}

/**
 * @title TestnetForwardingResolver
 * @notice Minimal resolver contract for testnet scenario runs.
 * @dev `EscrowSettings.customResolver` requires a contract address (not an EOA).
 *      This contract forwards resolver actions into `EscrowVault` so an owner EOA
 *      can trigger on-chain resolution flows while `msg.sender` at the vault is
 *      this contract (authorized resolver).
 */
contract TestnetForwardingResolver is ERC165, IResolver {
    error NotOwner(address caller);
    error ResolveNotImplemented();

    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165) returns (bool) {
        return interfaceId == type(IResolver).interfaceId || super.supportsInterface(interfaceId);
    }

    // ---- IResolver ----

    function onDisputeOpened(uint256 /*workflowId*/, bytes calldata /*disputeMetadata*/) external pure override {
        // no-op: testnet scenario harness doesn't require resolver-side bookkeeping
    }

    function resolve(
        uint256 /*workflowId*/,
        Payout[] calldata /*payouts*/,
        bytes calldata /*resolutionMetadata*/
    ) external pure override {
        // Not used by current escrow flows (this protocol uses resolver-cancel/release paths).
        revert ResolveNotImplemented();
    }

    function resolverMetadata() external pure override returns (string memory name, string memory version) {
        return ("TestnetForwardingResolver", "1.0.0");
    }

    // ---- Forwarded resolver actions ----

    function cancelEscrow(address escrow, uint256 workflowId, bytes32 resolutionHash) external onlyOwner returns (bool) {
        return IEscrowResolverActions(escrow).cancelAsDisputeResolver(workflowId, resolutionHash);
    }

    function releaseEscrow(address escrow, uint256 workflowId, bytes32 resolutionHash) external onlyOwner returns (bool) {
        return IEscrowResolverActions(escrow).releaseAsDisputeResolver(workflowId, resolutionHash);
    }
}

