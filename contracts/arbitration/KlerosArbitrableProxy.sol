// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import './IArbitrator.sol';
import './IArbitrable.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

interface IBaseEscrowSettlement {
    function releaseAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) external returns (bool);
    function cancelAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash) external returns (bool);
}

/**
 * @title KlerosArbitrableProxy
 * @notice Proxy contract that integrates Kleros arbitration with BaseEscrow
 * @dev Implements IArbitrable to receive rulings from Kleros and IResolutionModule to integrate with BaseEscrow
 */
contract KlerosArbitrableProxy is AccessControl, ReentrancyGuard, IArbitrable, IResolutionModule {
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');

    IArbitrator public arbitrator;

    // Mapping: escrowContract => workflowId => klerosDisputeID + 1 (0 means no dispute)
    mapping(address => mapping(uint256 => uint256)) public workflowToKlerosDispute;

    // Mapping: klerosDisputeID => workflowId
    mapping(uint256 => uint256) public klerosDisputeToWorkflow;
    
    // Mapping: klerosDisputeID => escrowContract
    mapping(uint256 => address) public klerosDisputeToEscrow;

    // Mapping: escrowContract => workflowId => dispute metadata
    mapping(address => mapping(uint256 => DisputeMetadata)) public disputes;

    struct DisputeMetadata {
        address arbitrable;
        uint256 klerosDisputeId;
        uint256 choices;
        bytes extraData;
        bool resolved;
        uint256 ruling;
        address from;
        address to;
        uint256 amount;
    }

    event DisputeCreated(
        uint256 indexed workflowId,
        uint256 indexed klerosDisputeId,
        IArbitrator indexed arbitrator
    );

    event EvidenceSubmitted(
        uint256 indexed workflowId,
        uint256 indexed klerosDisputeId,
        address indexed submitter,
        string evidence
    );

    event RulingExecuted(uint256 indexed workflowId, uint256 indexed klerosDisputeId, uint256 ruling);
    event SettlementPropagated(uint256 indexed workflowId, address indexed escrowContract, bool isRelease, bool success);

    constructor(address _arbitrator, address _admin) {
        require(_arbitrator != address(0), 'Invalid arbitrator');
        require(_admin != address(0), 'Invalid admin');

        arbitrator = IArbitrator(_arbitrator);

        // OpenZeppelin best practice: Grant DEFAULT_ADMIN_ROLE to deployer
        // Deployment scripts will transfer this to TimelockController
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /**
     * @notice Register an escrow contract that can create disputes
     */
    function registerEscrowContract(address escrow) external onlyRole(ROLE_TIMELOCK) {
        require(escrow != address(0), 'Invalid escrow address');
        _grantRole(ROLE_ESCROW_CONTRACT, escrow);
    }

    /**
     * @notice Create a dispute in Kleros for an escrow workflow
     * @param workflowId The escrow workflow ID
     * @param choices Number of ruling choices (typically 2: release or cancel)
     * @param extraData Additional data for Kleros
     * @param escrowData Encoded escrow data (token, from, to, amount)
     */
    function createDispute(
        uint256 workflowId,
        address escrowContract,
        uint256 choices,
        bytes calldata extraData,
        bytes calldata escrowData
    )
        external
        payable
        nonReentrant
        returns (uint256 klerosDisputeId)
    {
        require(workflowToKlerosDispute[escrowContract][workflowId] == 0, 'Dispute already exists');

        // Decode escrow data
        (, address from, address to, uint256 amount, ) = abi.decode(
            escrowData,
            (address, address, address, uint256, uint256)
        );

        // Authorization check: Only escrow contract or associated participants
        if (!hasRole(ROLE_ESCROW_CONTRACT, _msgSender())) {
            require(_msgSender() == from || _msgSender() == to, 'Not authorized');
        }

        // Check arbitration cost
        uint256 cost = arbitrator.arbitrationCost(extraData);
        require(msg.value >= cost, 'Insufficient arbitration fee');

        // Create dispute in Kleros
        klerosDisputeId = arbitrator.createDispute{value: cost}(choices, extraData);

        // Store mappings (add 1 to klerosDisputeId for storage to distinguish from "no dispute")
        workflowToKlerosDispute[escrowContract][workflowId] = klerosDisputeId + 1;
        klerosDisputeToWorkflow[klerosDisputeId] = workflowId;
        klerosDisputeToEscrow[klerosDisputeId] = escrowContract;

        // Store dispute metadata
        disputes[escrowContract][workflowId] = DisputeMetadata({
            arbitrable: address(this),
            klerosDisputeId: klerosDisputeId,
            choices: choices,
            extraData: extraData,
            resolved: false,
            ruling: 0,
            from: from,
            to: to,
            amount: amount
        });

        emit DisputeCreated(workflowId, klerosDisputeId, arbitrator);

        // Refund excess
        if (msg.value > cost) {
            (bool success, ) = payable(_msgSender()).call{value: msg.value - cost}('');
            require(success, 'Refund failed');
        }

        return klerosDisputeId;
    }

    /**
     * @notice Submit evidence for a dispute
     * @param workflowId The escrow workflow ID
     * @param escrowContract Address of the escrow contract
     * @param evidence Evidence string (typically IPFS hash or URL)
     */
    function submitEvidence(uint256 workflowId, address escrowContract, string calldata evidence) external {
        require(workflowToKlerosDispute[escrowContract][workflowId] != 0, 'Dispute does not exist');
        DisputeMetadata storage dispute = disputes[escrowContract][workflowId];
        require(!dispute.resolved, 'Dispute already resolved');

        // Anyone can submit evidence (sender, recipient, or others)
        emit EvidenceSubmitted(workflowId, dispute.klerosDisputeId, _msgSender(), evidence);
    }

    /**
     * @notice Called by Kleros arbitrator to give ruling
     * @param _disputeID The Kleros dispute ID
     * @param _ruling The ruling (0 = refused to rule, 1 = release to recipient, 2 = cancel to sender)
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        require(_msgSender() == address(arbitrator), 'Only arbitrator can rule');

        // BUG FIX: workflowId 0 is valid, use escrowContract to validate existence
        address escrowContract = klerosDisputeToEscrow[_disputeID];
        require(escrowContract != address(0), 'Unknown dispute');
        
        uint256 workflowId = klerosDisputeToWorkflow[_disputeID];

        DisputeMetadata storage dispute = disputes[escrowContract][workflowId];
        require(!dispute.resolved, 'Already resolved');

        dispute.resolved = true;
        dispute.ruling = _ruling;

        emit Ruling(arbitrator, _disputeID, _ruling);
        emit RulingExecuted(workflowId, _disputeID, _ruling);

        // Automatic propagation to BaseEscrow
        _propagateRuling(workflowId, escrowContract, _ruling);
    }

    /**
     * @notice Manually trigger ruling propagation if automatic attempt failed
     * @param workflowId The escrow workflow ID
     * @param escrowContract Address of the escrow contract
     */
    function propagateRuling(uint256 workflowId, address escrowContract) external nonReentrant {
        require(workflowToKlerosDispute[escrowContract][workflowId] != 0, 'Dispute does not exist');
        DisputeMetadata storage dispute = disputes[escrowContract][workflowId];
        
        if (!dispute.resolved) {
            // Check if arbitrator has ruled but hasn't called rule() yet (unlikely but possible in some arbitrator implementations)
            IArbitrator.DisputeStatus status = arbitrator.disputeStatus(dispute.klerosDisputeId);
            if (status == IArbitrator.DisputeStatus.Solved) {
                dispute.ruling = arbitrator.currentRuling(dispute.klerosDisputeId);
                dispute.resolved = true;
            } else {
                revert('Not yet resolved by Kleros');
            }
        }

        _propagateRuling(workflowId, escrowContract, dispute.ruling);
    }

    /**
     * @dev Internal helper for propagating ruling to BaseEscrow
     */
    function _propagateRuling(uint256 workflowId, address escrowContract, uint256 ruling) internal {
        if (ruling == 0) return; // Refused to rule - requires manual intervention or timeout

        bytes32 resolutionHash = keccak256(abi.encodePacked('KlerosRuling', ruling, block.timestamp));
        bool success;

        if (ruling == 1) { // Release
            try IBaseEscrowSettlement(escrowContract).releaseAsDisputeResolver(workflowId, resolutionHash) returns (bool s) {
                success = s;
            } catch {}
            emit SettlementPropagated(workflowId, escrowContract, true, success);
        } else if (ruling == 2) { // Cancel
            try IBaseEscrowSettlement(escrowContract).cancelAsDisputeResolver(workflowId, resolutionHash) returns (bool s) {
                success = s;
            } catch {}
            emit SettlementPropagated(workflowId, escrowContract, false, success);
        }
    }

    /**
     * @notice Get the current ruling for a workflow
     * @param workflowId The escrow workflow ID
     * @param escrowContract Address of the escrow contract
     */
    function getRuling(uint256 workflowId, address escrowContract) external view returns (bool resolved, uint256 ruling) {
        // Check if dispute exists
        if (workflowToKlerosDispute[escrowContract][workflowId] == 0) {
            return (false, 0);
        }

        DisputeMetadata storage dispute = disputes[escrowContract][workflowId];

        // Check if Kleros has a ruling
        if (dispute.resolved) {
            return (true, dispute.ruling);
        }

        // Check Kleros arbitrator for current ruling
        IArbitrator.DisputeStatus status = arbitrator.disputeStatus(dispute.klerosDisputeId);
        if (status == IArbitrator.DisputeStatus.Solved) {
            uint256 currentRuling = arbitrator.currentRuling(dispute.klerosDisputeId);
            return (true, currentRuling);
        }

        return (false, 0);
    }

    /**
     * @notice Check arbitration cost
     */
    function getArbitrationCost(bytes calldata extraData) external view returns (uint256) {
        return arbitrator.arbitrationCost(extraData);
    }

    // ========== IResolutionModule Implementation ==========

    /**
     * @notice Initialize a new dispute in the module
     */
    function initializeDispute(
        uint256,
        address,
        address,
        bytes32
    ) external pure override {
        // No-op: Kleros disputes are created explicitly via createDispute
    }

    /**
     * @notice Record a resolution outcome
     */
    function recordResolution(
        uint256,
        address,
        address,
        ResolutionOutcome,
        uint256
    ) external pure override {
        // No-op: Kleros resolution is handled via rule() callback
    }

    /**
     * @notice Check if an address is authorized to resolve a dispute
     */
    function isAuthorizedDisputeResolver(
        uint256,
        address,
        address disputeResolver,
        bytes calldata
    ) external view override returns (bool authorized, uint8 role) {
        // Only this contract (Kleros proxy) can resolve disputes
        return (disputeResolver == address(this), 2); // Role 2 = external resolver
    }

    /**
     * @notice Get dispute resolver for a workflow
     */
    function getDisputeResolver(
        uint256,
        address,
        bytes calldata
    ) external view override returns (address resolver, uint8 level) {
        return (address(this), 2); // Level 2 = external resolver
    }

    /**
     * @notice Check if escalation is possible (not applicable for Kleros - it's final)
     */
    function canEscalate(
        uint256,
        address,
        uint8,
        bytes calldata
    ) external pure override returns (bool, address, uint256) {
        return (false, address(0), 0); // No further escalation from Kleros
    }

    /**
     * @notice Execute escalation (not applicable for Kleros)
     */
    function executeEscalation(
        uint256,
        address,
        bytes calldata
    ) external pure override returns (bool, address, uint8) {
        revert('No escalation from Kleros');
    }

    /**
     * @notice Get required appeal bond for escalation (DR v2)
     * @dev Kleros is final level - no bonds required (returns 0)
     */
    function getRequiredAppealBond(
        uint256,
        address,
        uint8,
        bytes calldata
    ) external pure override returns (uint256 amount, address token) {
        return (0, address(0));
    }

    /**
     * @notice Get decision at a specific round
     */
    function getDecisionAtRound(uint256 workflowId, address escrowContract, uint8 round) external view override returns (uint8 decision) {
        DisputeMetadata storage dispute = disputes[escrowContract][workflowId];
        if (dispute.resolved) {
            // Ruling 1 = RELEASE (enum 1), Ruling 2 = CANCEL (enum 2)
            return uint8(dispute.ruling);
        }
        return 0; // ResolutionOutcome.NONE
    }

    /**
     * @notice Get appeal deadline and current round
     */
    function getAppealDeadlineAndRound(
        uint256 /* workflowId */,
        address /* escrowContract */
    ) external pure override returns (uint256 appealDeadline, uint8 currentRound, bool isFinalRound) {
        return (0, 2, true); // Level 2 is final
    }

    /**
     * @notice Record a reversal
     */
    function recordReversal(uint256 /* workflowId */, address /* escrowContract */, uint8 /* priorRound */) external override {}

    /**
     * @notice Finalize a dispute
     */
    function finalizeDispute(uint256 /* workflowId */, address /* escrowContract */) external override {}

    /**
     * @notice Module metadata
     */
    function moduleName() external pure override returns (string memory) {
        return 'KlerosArbitrableProxy';
    }

    function moduleVersion() external pure override returns (string memory) {
        return '1.0.0';
    }

    /**
     * @notice ERC-165 support
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, IERC165) returns (bool) {
        return
            interfaceId == type(IResolutionModule).interfaceId ||
            interfaceId == type(IArbitrable).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
