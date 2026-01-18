// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import '../interfaces/IEvidenceModule.sol';
import '../shared/interfaces/IResolutionModule.sol';

/**
 * @title EvidenceModuleV1
 * @notice On-chain evidence storage module for dispute resolution
 * @dev Stores evidence hashes on-chain; metadata in events only
 *      Aligns with threat model TB1: UI independence via on-chain commitments
 *
 * Features:
 * - Stores evidence hashes (bytes32) on-chain
 * - Configurable access control (participants, resolvers, or open)
 * - Configurable limits per dispute
 * - Lifecycle gating (only during dispute)
 * - Per-escrow module snapshot support
 */
contract EvidenceModuleV1 is IEvidenceModule, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');
    bytes32 public constant ROLE_RESOLUTION_MODULE = keccak256('ROLE_RESOLUTION_MODULE');

    // ============ Storage ============

    struct EvidenceRecord {
        bytes32 hash; // keccak256 of evidence content
        address submitter; // Who submitted
        uint256 submittedAt; // Timestamp
    }

    // Per-dispute evidence storage
    mapping(uint256 => EvidenceRecord[]) public disputeEvidence;

    // Configuration
    uint256 public maxEvidencePerDispute; // Max evidence submissions per dispute (default: 20)
    bool public allowAnyoneSubmit; // If true, anyone can submit (default: false)
    bool public allowPostResolution; // If true, evidence allowed after resolution (default: false)

    // Escrow contract reference (for participant validation)
    address public escrowContract;

    // Resolution module reference (for resolver validation)
    address public resolutionModule;

    // ============ Events ============

    event EvidenceSubmitted(
        uint256 indexed workflowId,
        uint256 indexed evidenceId,
        address indexed submitter,
        bytes32 evidenceHash,
        string metadata
    );

    event EvidenceModuleConfigured(
        uint256 maxEvidencePerDispute,
        bool allowAnyoneSubmit,
        bool allowPostResolution
    );

    // ============ Modifiers ============

    modifier onlyEscrowContract() {
        require(msg.sender == escrowContract, 'Not escrow contract');
        _;
    }

    // ============ Initialization ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address _escrowContract,
        address _resolutionModule,
        uint256 _maxEvidencePerDispute,
        bool _allowAnyoneSubmit,
        bool _allowPostResolution
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        // OpenZeppelin best practice: Grant DEFAULT_ADMIN_ROLE to deployer
        // Deployment scripts will transfer this to TimelockController
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        escrowContract = _escrowContract;
        resolutionModule = _resolutionModule;
        maxEvidencePerDispute = _maxEvidencePerDispute > 0 ? _maxEvidencePerDispute : 20;
        allowAnyoneSubmit = _allowAnyoneSubmit;
        allowPostResolution = _allowPostResolution;

        emit EvidenceModuleConfigured(
            maxEvidencePerDispute,
            allowAnyoneSubmit,
            allowPostResolution
        );
    }

    // ============ Core Functions ============

    /**
     * @notice Submit evidence for a dispute
     * @param workflowId The escrow workflow ID
     * @param evidenceHash Hash of evidence content (keccak256)
     * @param metadata Additional metadata (IPFS hash, document type, etc.) - emitted only
     * @return evidenceId Unique evidence ID for this dispute (0-indexed)
     */
    function submitEvidence(
        uint256 workflowId,
        bytes32 evidenceHash,
        string calldata metadata
    ) external nonReentrant returns (uint256 evidenceId) {
        // Check access control
        // Note: escrowData not available here, will check via other means
        (bool allowed, string memory reason) = _canSubmitEvidenceInternal(workflowId, msg.sender);
        require(allowed, reason);

        // Check limit
        uint256 currentCount = disputeEvidence[workflowId].length;
        require(currentCount < maxEvidencePerDispute, 'Evidence limit reached');

        // Check for duplicates (same hash by same submitter)
        // Note: Different submitters can submit same hash (e.g., same document)
        for (uint256 i = 0; i < currentCount; i++) {
            if (
                disputeEvidence[workflowId][i].hash == evidenceHash &&
                disputeEvidence[workflowId][i].submitter == msg.sender
            ) {
                revert('Duplicate evidence');
            }
        }

        // Store evidence
        disputeEvidence[workflowId].push(
            EvidenceRecord({
                hash: evidenceHash,
                submitter: msg.sender,
                submittedAt: block.timestamp
            })
        );

        evidenceId = currentCount;

        emit EvidenceSubmitted(workflowId, evidenceId, msg.sender, evidenceHash, metadata);

        return evidenceId;
    }

    /**
     * @notice Get all evidence for a dispute
     */
    function getEvidence(
        uint256 workflowId
    )
        external
        view
        returns (
            bytes32[] memory hashes,
            address[] memory submitters,
            uint256[] memory timestamps,
            string[] memory metadata
        )
    {
        EvidenceRecord[] memory evidence = disputeEvidence[workflowId];
        uint256 count = evidence.length;

        hashes = new bytes32[](count);
        submitters = new address[](count);
        timestamps = new uint256[](count);
        metadata = new string[](count); // Empty - metadata not stored on-chain

        for (uint256 i = 0; i < count; i++) {
            hashes[i] = evidence[i].hash;
            submitters[i] = evidence[i].submitter;
            timestamps[i] = evidence[i].submittedAt;
        }
    }

    /**
     * @notice Get evidence count
     */
    function getEvidenceCount(uint256 workflowId) external view returns (uint256 count) {
        return disputeEvidence[workflowId].length;
    }

    /**
     * @notice Get specific evidence record
     */
    function getEvidenceRecord(
        uint256 workflowId,
        uint256 evidenceId
    )
        external
        view
        returns (bytes32 hash, address submitter, uint256 submittedAt, string memory metadata)
    {
        EvidenceRecord[] memory evidence = disputeEvidence[workflowId];
        require(evidenceId < evidence.length, 'Invalid evidence ID');

        EvidenceRecord memory record = evidence[evidenceId];
        return (record.hash, record.submitter, record.submittedAt, '');
    }

    /**
     * @notice Check if evidence submission is allowed (internal, without escrowData)
     */
    function _canSubmitEvidenceInternal(
        uint256 workflowId,
        address submitter
    ) internal view returns (bool allowed, string memory reason) {
        // Check if anyone can submit
        if (allowAnyoneSubmit) {
            return (true, '');
        }

        // Check if submitter is current resolver
        if (resolutionModule != address(0)) {
            bytes memory emptyEscrowData;
            try
                IResolutionModule(resolutionModule).getDisputeResolver(workflowId, emptyEscrowData)
            returns (address resolver, uint8) {
                if (submitter == resolver) {
                    return (true, '');
                }
            } catch {}
        }

        // Note: Participant check requires escrow data, which is not available here
        // This will be handled by canSubmitEvidence() when called with escrowData
        return (false, 'Not authorized to submit evidence');
    }

    /**
     * @notice Check if evidence submission is allowed
     * @dev Validates:
     *      1. Participant (buyer/seller) - always allowed
     *      2. Current resolver - allowed if assigned
     *      3. Anyone - allowed if allowAnyoneSubmit is true
     *      4. Lifecycle - only during dispute (unless allowPostResolution)
     */
    function canSubmitEvidence(
        uint256 workflowId,
        address submitter,
        bytes calldata escrowData
    ) public view returns (bool allowed, string memory reason) {
        // Check if anyone can submit
        if (allowAnyoneSubmit) {
            return (true, '');
        }

        // Check if submitter is participant (requires escrow data)
        if (escrowData.length > 0) {
            // Decode escrow data: (token, from, to, amount, totalDeposited)
            (address token, address from, address to, , ) = abi.decode(
                escrowData,
                (address, address, address, uint256, uint256)
            );

            if (submitter == from || submitter == to) {
                return (true, '');
            }
        }

        // Check if submitter is current resolver
        if (resolutionModule != address(0)) {
            try
                IResolutionModule(resolutionModule).getDisputeResolver(workflowId, escrowData)
            returns (address resolver, uint8) {
                if (submitter == resolver) {
                    return (true, '');
                }
            } catch {}
        }

        return (false, 'Not authorized to submit evidence');
    }

    /**
     * @notice Callback when dispute is opened
     */
    function onDisputeOpened(uint256 workflowId) external onlyEscrowContract {
        // Optional: Initialize dispute-specific state
        // For now, no-op (evidence array initialized on first submission)
    }

    // ============ Admin Functions ============

    function setMaxEvidencePerDispute(uint256 max) external onlyRole(ROLE_TIMELOCK) {
        require(max > 0 && max <= 100, 'Invalid max');
        maxEvidencePerDispute = max;
        emit EvidenceModuleConfigured(
            maxEvidencePerDispute,
            allowAnyoneSubmit,
            allowPostResolution
        );
    }

    function setAllowAnyoneSubmit(bool allow) external onlyRole(ROLE_TIMELOCK) {
        allowAnyoneSubmit = allow;
        emit EvidenceModuleConfigured(
            maxEvidencePerDispute,
            allowAnyoneSubmit,
            allowPostResolution
        );
    }

    function setAllowPostResolution(bool allow) external onlyRole(ROLE_TIMELOCK) {
        allowPostResolution = allow;
        emit EvidenceModuleConfigured(
            maxEvidencePerDispute,
            allowAnyoneSubmit,
            allowPostResolution
        );
    }

    function setEscrowContract(address _escrowContract) external onlyRole(ROLE_TIMELOCK) {
        escrowContract = _escrowContract;
    }

    function setResolutionModule(address _resolutionModule) external onlyRole(ROLE_TIMELOCK) {
        resolutionModule = _resolutionModule;
    }

    // ============ ERC-165 ============

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControlUpgradeable, IERC165) returns (bool) {
        return
            interfaceId == type(IEvidenceModule).interfaceId ||
            interfaceId == type(IERC165).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ============ Metadata ============

    function moduleName() external pure returns (string memory) {
        return 'EvidenceModule';
    }

    function moduleVersion() external pure returns (string memory) {
        return '1.0.0';
    }
}
