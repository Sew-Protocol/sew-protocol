// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './ResolverIncentiveModuleV2.sol';
import '../../shared/interfaces/IBondLedger.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/**
 * @title ResolverIncentiveModuleV2BondLedger
 * @notice BondLedger-backed compatibility facade for DR v2 incentive module.
 * @dev Substitutes BondLedger for the embedded appeal-bond custody and settlement
 *      that ResolverIncentiveModuleV2 keeps inline. Behavioural semantics (bond
 *      amounts, refund recipients, resolver allocations, rounding, forfeiture
 *      reserve, metrics, legacy events) are preserved by delegating custody and
 *      exact settlement to BondLedger while retaining Sew-specific allocation
 *      computation, resolver tracking, metrics, and events in this contract.
 */
contract ResolverIncentiveModuleV2BondLedger is ResolverIncentiveModuleV2 {
    using SafeERC20 for IERC20;

    IBondLedger public immutable bondLedger;

    /// @notice Protocol address receiving forfeited bond principal as a reserve.
    /// @dev BondLedger tracks forfeited principal in its own forfeitedBondReserve.
    address public constant FORFEIT_DESTINATION = address(0x000000000000000000000000000000000000dEaD);

    error BondLedgerRequired();

    constructor(
        address initialOwner,
        address initialLibrary,
        address bondLedgerAddr
    ) ResolverIncentiveModuleV2(initialOwner, initialLibrary) {
        if (bondLedgerAddr == address(0)) revert BondLedgerRequired();
        bondLedger = IBondLedger(bondLedgerAddr);
    }

    // ============ Posting ============

    function recordAppealBond(
        uint256 workflowId,
        address escrowContract,
        address depositor,
        address escalatedBy,
        uint256 amount,
        address token,
        uint8 round
    ) external payable override onlyEscrowContract {
        require(depositor != address(0), 'Invalid depositor');
        require(escalatedBy != address(0), 'Invalid escalatedBy');
        require(amount > 0, 'Invalid amount');
        require(round > 0 && round <= 2, 'Invalid round');

        bytes32 bondId = _bondId(escrowContract, workflowId, round);
        require(!bondLedger.hasBond(bondId), 'Bond already exists');

        if (token == address(0)) {
            require(msg.value == amount, 'ETH amount mismatch');
            require(depositor == escalatedBy, 'Depositor must be escalator for ETH bonds');
            bondLedger.postBond{value: amount}(
                bondId, escrowContract, escalatedBy, escalatedBy, address(0), amount,
                keccak256(abi.encode(workflowId, round)), bytes32(0)
            );
        } else {
            _requirePayoutToken(escrowContract, workflowId, token);
            // Pull from depositor into this facade (depositor approves the facade),
            // then approve BondLedger so it can take custody.
            IERC20(token).safeTransferFrom(depositor, address(this), amount);
            IERC20(token).safeIncreaseAllowance(address(bondLedger), amount);
            bondLedger.postBond(
                bondId, escrowContract, escalatedBy, address(this), token, amount,
                keccak256(abi.encode(workflowId, round)), bytes32(0)
            );
            IERC20(token).approve(address(bondLedger), 0);
        }

        totalBondsPosted += amount;
        escalationDepthHistogram[round]++;

        emit AppealBondRecorded(workflowId, round, depositor, amount, token);
    }

    // ============ Settlement ============

    function distributeAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 round,
        bool outcomeFlipped
    ) external override onlyEscrowOrResolutionModule nonReentrant {
        require(round < 2, 'Invalid round - no higher round');
        uint8 bondRound = round + 1;
        bytes32 bondId = _bondId(escrowContract, workflowId, bondRound);

        IBondLedger.BondPosition memory pos = bondLedger.getBond(bondId);
        require(pos.principal > 0, 'No bond recorded');

        if (outcomeFlipped) {
            // Appeal succeeded - refund to economic payer (escalator)
            IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
            allocs[0] = IBondLedger.Allocation(pos.payer, pos.principal);
            bondLedger.settleBond(bondId, allocs, IBondLedger.SettlementKind.REFUND);
            totalBondsRefunded += pos.principal;
            emit AppealBondRefundClaimable(workflowId, bondRound, pos.payer, pos.principal, pos.asset);
        } else {
            // Appeal failed - pay to resolvers from prior round, or forfeit if none
            (address[] memory resolvers, uint256 count) = _eligibleResolvers(escrowContract, workflowId, round);
            if (count == 0) {
                IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
                allocs[0] = IBondLedger.Allocation(FORFEIT_DESTINATION, pos.principal);
                bondLedger.settleBond(bondId, allocs, IBondLedger.SettlementKind.FORFEIT);
                totalBondsForfeited += pos.principal;
                emit AppealBondForfeited(workflowId, round, pos.principal, pos.asset, 'No resolvers');
            } else {
                uint256 amountPerResolver = pos.principal / count;
                uint256 remainder = pos.principal % count;
                IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](count);
                for (uint256 i = 0; i < count; i++) {
                    uint256 payment = amountPerResolver;
                    if (i < remainder) payment += 1;
                    allocs[i] = IBondLedger.Allocation(resolvers[i], payment);
                }
                bondLedger.settleBond(bondId, allocs, IBondLedger.SettlementKind.RESOLVER_PAYOUT);
                totalBondsPaidToResolvers += pos.principal;
                emit AppealBondPaidToResolvers(workflowId, round, resolvers, pos.principal, pos.asset);
            }
        }
    }

    function forfeitAppealBondLedger(
        uint256 workflowId,
        address escrowContract,
        uint8 round,
        string calldata reason
    ) external onlyEscrowContract nonReentrant {
        bytes32 bondId = _bondId(escrowContract, workflowId, round);
        IBondLedger.BondPosition memory pos = bondLedger.getBond(bondId);
        require(pos.principal > 0, 'No bond recorded');

        IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
        allocs[0] = IBondLedger.Allocation(FORFEIT_DESTINATION, pos.principal);
        bondLedger.settleBond(bondId, allocs, IBondLedger.SettlementKind.FORFEIT);

        totalBondsForfeited += pos.principal;
        emit AppealBondForfeited(workflowId, round, pos.principal, pos.asset, reason);
    }

    function onDisputeFinalized(
        uint256 workflowId,
        address escrowContract,
        uint8 finalRound,
        ResolutionOutcome /* finalDecision */
    ) external override onlyEscrowOrResolutionModule {
        for (uint8 round = 0; round <= finalRound; round++) {
            bytes32 bondId = _bondId(escrowContract, workflowId, round);
            if (!bondLedger.hasBond(bondId)) continue;
            IBondLedger.BondPosition memory pos = bondLedger.getBond(bondId);
            if (uint8(pos.status) != uint8(IBondLedger.BondStatus.PENDING)) continue;

            IBondLedger.Allocation[] memory allocs = new IBondLedger.Allocation[](1);
            allocs[0] = IBondLedger.Allocation(FORFEIT_DESTINATION, pos.principal);
            bondLedger.settleBond(bondId, allocs, IBondLedger.SettlementKind.FORFEIT);

            totalBondsForfeited += pos.principal;
            emit AppealBondForfeited(workflowId, round, pos.principal, pos.asset, 'Finalize cleanup');
        }
    }

    // ============ Claims ============

    function claimBondRefundLedger(uint256 workflowId, address escrowContract, address token) external nonReentrant {
        uint256 total;
        for (uint8 round = 1; round <= 2; round++) {
            bytes32 bondId = _bondId(escrowContract, workflowId, round);
            uint256 amt = bondLedger.getClaimable(bondId, _msgSender());
            if (amt > 0) {
                bondLedger.claimFor(bondId, _msgSender());
                total += amt;
            }
        }
        require(total > 0, 'Nothing to claim');
        totalBondRefundsClaimed += total;
        emit BondRefundClaimed(workflowId, _msgSender(), total, token);
    }

    function claimPaymentLedger(uint256 workflowId, address escrowContract, address token) external nonReentrant {
        uint256 total;
        for (uint8 round = 1; round <= 2; round++) {
            bytes32 bondId = _bondId(escrowContract, workflowId, round);
            uint256 amt = bondLedger.getClaimable(bondId, _msgSender());
            if (amt > 0) {
                bondLedger.claimFor(bondId, _msgSender());
                total += amt;
            }
        }
        require(total > 0, 'Nothing to claim');
        emit PaymentClaimed(workflowId, _msgSender(), total);
    }

    // ============ Internal ============

    function _bondId(address escrowContract, uint256 workflowId, uint8 round) internal pure returns (bytes32) {
        return keccak256(abi.encode(escrowContract, workflowId, round));
    }

    function _eligibleResolvers(
        address escrowContract,
        uint256 workflowId,
        uint8 priorRound
    ) internal view returns (address[] memory resolvers, uint256 count) {
        ResolverRecord[] storage all = disputeResolvers[escrowContract][workflowId];
        resolvers = new address[](all.length);
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].level == priorRound) {
                resolvers[count] = all[i].resolver;
                count++;
            }
        }
    }
}
