// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

// Sole owner of BaseEscrow state. Declaration order is intentionally preserved.
import '../types/EscrowTypes.sol';
import '../ops/YieldOps.sol';
import './EscrowCreationPolicy.sol';
import './BondCollector.sol';
import '../libraries/ModuleSnapshotLibrary.sol';

abstract contract EscrowStorage {
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant ROLE_ADMIN_CONTRACT = keccak256('ROLE_ADMIN_CONTRACT');
    bytes32 public constant ROLE_KEEPER = keccak256('ROLE_KEEPER');
    uint256 public escrowFee;
    uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;
    uint256 public constant MAX_ESCROW_FEE_BPS = 200;
    uint256 public constant MAX_AUTOMATION_RANGE = 100;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 3000;
    uint256 public constant DEFAULT_YIELD_PROTOCOL_FEE_BPS = 3000;
    EscrowTransfer[] public escrowTransfers;
    address public escrowFeeAddress;
    uint256 public yieldProtocolFeeBps;
    uint256 public appealBondProtocolFeeBps;
    address public disputeResolutionModule;
    TimeoutConfig public timeoutConfig;
    mapping(uint256 => uint256) public disputeRaisedTimestamp;
    mapping(uint256 => EscrowSettings) public escrowSettings;
    mapping(uint256 => uint256) public amountReleased;
    mapping(uint256 => mapping(address => uint256)) public claimableBalances;
    mapping(address => uint256) public totalClaimableAssets;
    mapping(address => mapping(address => uint256)) public claimableBondProtocolFees;
    mapping(address => uint256) public claimableExcessEthRefunds;
    // ── PRF adjudication seam (design marker; not implemented) ──────────────────
    // The decision → finality → settlement pipeline attaches here. A future
    // adjudication closure (`finalOutcomeRoot` / `adjudicationClosureRoot`) would
    // be captured at the decision transition and verified before realization.
    //
    // SECURITY NOTE: `resolutionHash` is currently NON-BINDING. It is supplied by
    // the authorized resolver / Kleros proxy and stored + emitted, but is never
    // verified against a rooted outcome (see BaseEscrow._executeResolution). It is
    // reserved as the likely closure slot; treat its presence as a placeholder, not
    // as settlement authority.
    struct PendingSettlement { bool exists; bool isRelease; uint256 appealDeadline; bytes32 resolutionHash; }
    mapping(uint256 => PendingSettlement) public pendingSettlements;
    struct SplitProposal { address proposer; uint256 buyerAmount; uint256 sellerAmount; uint64 expiry; bool active; }
    mapping(uint256 => SplitProposal) public splitProposals;
    uint256 public minDisputeEscrowValue;
    uint32 public maxDisputesPerSenderPerDay;
    mapping(address => uint64) public senderDisputeWindowStart;
    mapping(address => uint32) public senderDisputeCount;
    uint64 public escalationCooldown;
    mapping(address => uint64) public lastEscalationTimestamp;
    mapping(address => uint32) public addressEscalationCount;
    struct EscrowTimeoutPolicySnapshot { bool pendingAutoCancelEnabled; bool disputedTimeoutEnabled; }
    mapping(uint256 => EscrowTimeoutPolicySnapshot) public timeoutPolicySnapshots;
    mapping(uint256 => address) public v25YieldModules;
    mapping(uint256 => uint256) public v25YieldPrincipals;
    mapping(uint256 => ModuleSnapshot) public moduleSnapshots;
    mapping(uint256 => address) public appealBondFeeRecipients;
    mapping(uint256 => uint256) public workflowResolutionConfigVersion;
    YieldOps public yieldOps;
    BondCollector public bondCollector;
    EscrowCreationPolicy public creationPolicy;
}
