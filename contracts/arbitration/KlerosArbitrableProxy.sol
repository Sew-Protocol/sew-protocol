// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "./IArbitrator.sol";
import "./IArbitrable.sol";
import "../shared/interfaces/IResolutionModule.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title KlerosArbitrableProxy
 * @notice Proxy contract that integrates Kleros arbitration with BaseEscrow
 * @dev Implements IArbitrable to receive rulings from Kleros and IResolutionModule to integrate with BaseEscrow
 */
contract KlerosArbitrableProxy is 
    Initializable, 
    AccessControlUpgradeable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable,
    IArbitrable,
    IResolutionModule 
{
    bytes32 public constant ROLE_ADMIN = keccak256("ROLE_ADMIN");
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256("ROLE_ESCROW_CONTRACT");

    IArbitrator public arbitrator;
    
    // Mapping: workflowId => klerosDisputeID + 1 (0 means no dispute)
    mapping(uint256 => uint256) public workflowToKlerosDispute;
    
    // Mapping: klerosDisputeID => workflowId
    mapping(uint256 => uint256) public klerosDisputeToWorkflow;
    
    // Mapping: workflowId => escrow contract address
    mapping(uint256 => address) public workflowToEscrow;
    
    // Mapping: workflowId => dispute metadata
    mapping(uint256 => DisputeMetadata) public disputes;
    
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
    
    event RulingExecuted(
        uint256 indexed workflowId,
        uint256 indexed klerosDisputeId,
        uint256 ruling
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Don't disable initializers for direct deployment in tests
        // _disableInitializers();
    }

    function initialize(address _arbitrator, address _admin) external initializer {
        require(_arbitrator != address(0), "Invalid arbitrator");
        require(_admin != address(0), "Invalid admin");
        
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        
        arbitrator = IArbitrator(_arbitrator);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ROLE_ADMIN, _admin);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ROLE_ADMIN) {}

    /**
     * @notice Register an escrow contract that can create disputes
     */
    function registerEscrowContract(address escrow) external onlyRole(ROLE_ADMIN) {
        require(escrow != address(0), "Invalid escrow address");
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
        uint256 choices,
        bytes calldata extraData,
        bytes calldata escrowData
    ) external payable onlyRole(ROLE_ESCROW_CONTRACT) nonReentrant returns (uint256 klerosDisputeId) {
        require(workflowToKlerosDispute[workflowId] == 0, "Dispute already exists");
        
        // Decode escrow data
        (, address from, address to, uint256 amount, ) = abi.decode(
            escrowData, 
            (address, address, address, uint256, uint256)
        );
        
        // Check arbitration cost
        uint256 cost = arbitrator.arbitrationCost(extraData);
        require(msg.value >= cost, "Insufficient arbitration fee");
        
        // Create dispute in Kleros
        klerosDisputeId = arbitrator.createDispute{value: cost}(choices, extraData);
        
        // Store mappings (add 1 to klerosDisputeId for storage to distinguish from "no dispute")
        workflowToKlerosDispute[workflowId] = klerosDisputeId + 1;
        klerosDisputeToWorkflow[klerosDisputeId] = workflowId;
        workflowToEscrow[workflowId] = msg.sender;
        
        // Store dispute metadata
        disputes[workflowId] = DisputeMetadata({
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
            (bool success, ) = payable(msg.sender).call{value: msg.value - cost}("");
            require(success, "Refund failed");
        }
        
        return klerosDisputeId;
    }

    /**
     * @notice Submit evidence for a dispute
     * @param workflowId The escrow workflow ID
     * @param evidence Evidence string (typically IPFS hash or URL)
     */
    function submitEvidence(uint256 workflowId, string calldata evidence) 
        external 
    {
        require(workflowToKlerosDispute[workflowId] != 0, "Dispute does not exist");
        DisputeMetadata storage dispute = disputes[workflowId];
        require(!dispute.resolved, "Dispute already resolved");
        
        // Anyone can submit evidence (sender, recipient, or others)
        emit EvidenceSubmitted(workflowId, dispute.klerosDisputeId, msg.sender, evidence);
    }

    /**
     * @notice Called by Kleros arbitrator to give ruling
     * @param _disputeID The Kleros dispute ID
     * @param _ruling The ruling (0 = refused to rule, 1 = release to recipient, 2 = cancel to sender)
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        require(msg.sender == address(arbitrator), "Only arbitrator can rule");
        
        uint256 workflowId = klerosDisputeToWorkflow[_disputeID];
        require(workflowId != 0, "Unknown dispute");
        
        DisputeMetadata storage dispute = disputes[workflowId];
        require(!dispute.resolved, "Already resolved");
        
        dispute.resolved = true;
        dispute.ruling = _ruling;
        
        emit Ruling(arbitrator, _disputeID, _ruling);
        emit RulingExecuted(workflowId, _disputeID, _ruling);
    }

    /**
     * @notice Get the current ruling for a workflow
     * @param workflowId The escrow workflow ID
     */
    function getRuling(uint256 workflowId) external view returns (bool resolved, uint256 ruling) {
        // Check if dispute exists
        if (workflowToKlerosDispute[workflowId] == 0) {
            return (false, 0);
        }
        
        DisputeMetadata storage dispute = disputes[workflowId];
        
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
     * @notice Check if an address is authorized to resolve a dispute
     */
    function isAuthorizedDisputeResolver(uint256, address disputeResolver, bytes calldata) 
        external 
        view 
        override 
        returns (bool authorized, uint8 role) 
    {
        // Only this contract (Kleros proxy) can resolve disputes
        return (disputeResolver == address(this), 2); // Role 2 = external resolver
    }

    /**
     * @notice Get dispute resolver for a workflow
     */
    function getDisputeResolver(uint256, bytes calldata) 
        external 
        view 
        override 
        returns (address resolver, uint8 level) 
    {
        return (address(this), 2); // Level 2 = external resolver
    }

    /**
     * @notice Check if escalation is possible (not applicable for Kleros - it's final)
     */
    function canEscalate(uint256, uint8, bytes calldata) 
        external 
        pure 
        override 
        returns (bool, address, uint256) 
    {
        return (false, address(0), 0); // No further escalation from Kleros
    }

    /**
     * @notice Execute escalation (not applicable for Kleros)
     */
    function executeEscalation(uint256, bytes calldata) 
        external 
        pure 
        override 
        returns (bool, address, uint8) 
    {
        revert("No escalation from Kleros");
    }

    /**
     * @notice Module metadata
     */
    function moduleName() external pure override returns (string memory) {
        return "KlerosArbitrableProxy";
    }

    function moduleVersion() external pure override returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice ERC-165 support
     */
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(AccessControlUpgradeable, IERC165) 
        returns (bool) 
    {
        return interfaceId == type(IResolutionModule).interfaceId ||
               interfaceId == type(IArbitrable).interfaceId ||
               super.supportsInterface(interfaceId);
    }
}
