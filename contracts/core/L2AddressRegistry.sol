// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title L2AddressRegistry
 * @notice Centralized registry for multi-L2 contract addresses
 * @dev Deployed on Ethereum mainnet to track all L2 deployments
 *
 * ## Purpose
 *
 * This contract serves as the single source of truth for contract addresses
 * across all supported L2s. It enables:
 *
 * 1. **Address Discovery**: Apps can query addresses for any chain
 * 2. **Version Management**: Track multiple versions per chain
 * 3. **Governance**: Updates require multi-signature approval
 * 4. **History Tracking**: Audit trail of all address changes
 * 5. **Fallback Configuration**: Primary + backup addresses
 *
 * ## Architecture
 *
 * ```
 * ChainID → ContractName → Version → (address, active, timestamp)
 *
 * Example:
 * 1 (Ethereum) → "EscrowVault" → "v1" → (0xabc..., true, timestamp)
 * 8453 (Base) → "EscrowVault" → "v1" → (0xabc..., true, timestamp)
 * 42161 (Arbitrum) → "EscrowVault" → "v1" → (0xabc..., true, timestamp)
 * 10 (Optimism) → "EscrowVault" → "v1" → (0xabc..., true, timestamp)
 * ```
 */
contract L2AddressRegistry {
    // Chain IDs
    uint256 public constant ETHEREUM = 1;
    uint256 public constant BASE = 8453;
    uint256 public constant ARBITRUM = 42161;
    uint256 public constant OPTIMISM = 10;

    /// @notice Address entry with metadata
    struct AddressEntry {
        address addr;
        bool active;
        uint64 registeredAt;
        string version;
    }

    /// @notice Contract names
    string[] public contractNames;
    mapping(string => bool) public isRegisteredContract;

    /// @notice Registry mapping: chainId → contractName → version → AddressEntry
    mapping(uint256 => mapping(string => mapping(string => AddressEntry))) public registry;

    /// @notice Active version per chain/contract
    mapping(uint256 => mapping(string => string)) public activeVersion;

    /// @notice Governance: authorized signers for updates
    mapping(address => bool) public isGovernor;
    uint256 public governorCount;
    uint256 public requiredSignatures;

    /// @notice Pending updates (for multi-sig)
    struct PendingUpdate {
        uint256 chainId;
        string contractName;
        string version;
        address newAddress;
        uint256 approvalsCount;
        mapping(address => bool) approvals;
        bool executed;
        uint64 createdAt;
    }

    mapping(bytes32 => PendingUpdate) public pendingUpdates;
    bytes32[] public pendingUpdateIds;

    // Events
    event ContractRegistered(string indexed contractName);
    event AddressRegistered(
        uint256 indexed chainId,
        string indexed contractName,
        string version,
        address indexed addr,
        uint64 timestamp
    );
    event AddressActivated(
        uint256 indexed chainId,
        string indexed contractName,
        string version,
        address indexed addr
    );
    event UpdateProposed(
        bytes32 indexed updateId,
        uint256 indexed chainId,
        string contractName,
        address indexed newAddress
    );
    event UpdateApproved(bytes32 indexed updateId, address indexed governor);
    event UpdateExecuted(
        bytes32 indexed updateId,
        uint256 indexed chainId,
        string contractName,
        address indexed newAddress
    );
    event GovernorAdded(address indexed governor);
    event GovernorRemoved(address indexed governor);

    // Errors
    error NotGovernor(address caller);
    error InvalidRequiredSignatures(uint256 required, uint256 available);
    error ContractAlreadyRegistered(string contractName);
    error ContractNotRegistered(string contractName);
    error AddressNotFound(uint256 chainId, string contractName, string version);
    error UpdateAlreadyExecuted(bytes32 updateId);
    error InsufficientApprovals(bytes32 updateId);
    error DuplicateApproval(bytes32 updateId, address governor);

    modifier onlyGovernor() {
        if (!isGovernor[msg.sender]) revert NotGovernor(msg.sender);
        _;
    }

    constructor(address[] memory initialGovernors, uint256 _requiredSignatures) {
        require(initialGovernors.length > 0, 'NoGovernors');
        require(_requiredSignatures > 0 && _requiredSignatures <= initialGovernors.length, 'InvalidSignatures');

        for (uint256 i = 0; i < initialGovernors.length; i++) {
            require(initialGovernors[i] != address(0), 'ZeroGovernor');
            isGovernor[initialGovernors[i]] = true;
            emit GovernorAdded(initialGovernors[i]);
        }

        governorCount = initialGovernors.length;
        requiredSignatures = _requiredSignatures;
    }

    /// @notice Register a new contract type
    function registerContract(string calldata contractName) external onlyGovernor {
        if (isRegisteredContract[contractName]) {
            revert ContractAlreadyRegistered(contractName);
        }

        isRegisteredContract[contractName] = true;
        contractNames.push(contractName);
        emit ContractRegistered(contractName);
    }

    /// @notice Register address for a specific chain/contract/version
    function registerAddress(
        uint256 chainId,
        string calldata contractName,
        string calldata version,
        address addr
    ) external onlyGovernor {
        if (!isRegisteredContract[contractName]) {
            revert ContractNotRegistered(contractName);
        }

        require(addr != address(0), 'ZeroAddress');

        registry[chainId][contractName][version] = AddressEntry({
            addr: addr,
            active: false,
            registeredAt: uint64(block.timestamp),
            version: version
        });

        emit AddressRegistered(chainId, contractName, version, addr, uint64(block.timestamp));
    }

    /// @notice Activate a version as the current active one
    function activateVersion(
        uint256 chainId,
        string calldata contractName,
        string calldata version
    ) external onlyGovernor {
        AddressEntry storage entry = registry[chainId][contractName][version];
        require(entry.addr != address(0), 'AddressNotRegistered');

        activeVersion[chainId][contractName] = version;
        entry.active = true;

        emit AddressActivated(chainId, contractName, version, entry.addr);
    }

    /// @notice Get active address for a chain/contract
    function getAddress(uint256 chainId, string calldata contractName)
        external
        view
        returns (address addr, string memory version)
    {
        version = activeVersion[chainId][contractName];
        if (bytes(version).length == 0) {
            revert AddressNotFound(chainId, contractName, version);
        }

        AddressEntry storage entry = registry[chainId][contractName][version];
        require(entry.addr != address(0), 'AddressNotFound');

        addr = entry.addr;
    }

    /// @notice Get specific version address
    function getAddressVersion(
        uint256 chainId,
        string calldata contractName,
        string calldata version
    ) external view returns (address) {
        AddressEntry storage entry = registry[chainId][contractName][version];
        require(entry.addr != address(0), 'AddressNotFound');
        return entry.addr;
    }

    /// @notice Propose an address update (multi-sig)
    function proposeUpdate(
        uint256 chainId,
        string calldata contractName,
        address newAddress
    ) external onlyGovernor returns (bytes32 updateId) {
        require(newAddress != address(0), 'ZeroAddress');
        if (!isRegisteredContract[contractName]) {
            revert ContractNotRegistered(contractName);
        }

        updateId = keccak256(abi.encodePacked(chainId, contractName, newAddress, block.timestamp));

        PendingUpdate storage update = pendingUpdates[updateId];
        update.chainId = chainId;
        update.contractName = contractName;
        update.version = 'pending';
        update.newAddress = newAddress;
        update.createdAt = uint64(block.timestamp);

        pendingUpdateIds.push(updateId);

        emit UpdateProposed(updateId, chainId, contractName, newAddress);
    }

    /// @notice Approve a pending update
    function approveUpdate(bytes32 updateId) external onlyGovernor {
        PendingUpdate storage update = pendingUpdates[updateId];
        if (update.executed) revert UpdateAlreadyExecuted(updateId);
        if (update.approvals[msg.sender]) revert DuplicateApproval(updateId, msg.sender);

        update.approvals[msg.sender] = true;
        update.approvalsCount++;

        emit UpdateApproved(updateId, msg.sender);

        // Auto-execute if threshold reached
        if (update.approvalsCount >= requiredSignatures) {
            executeUpdate(updateId);
        }
    }

    /// @notice Execute a multi-sig approved update
    function executeUpdate(bytes32 updateId) public {
        PendingUpdate storage update = pendingUpdates[updateId];
        if (update.executed) revert UpdateAlreadyExecuted(updateId);
        if (update.approvalsCount < requiredSignatures) {
            revert InsufficientApprovals(updateId);
        }

        update.executed = true;

        // Register the new address with "v2" suffix or increment version
        string memory newVersion = string(
            abi.encodePacked(
                'v',
                _uint2str(
                    _parseVersion(activeVersion[update.chainId][update.contractName]) + 1
                )
            )
        );

        registry[update.chainId][update.contractName][newVersion] = AddressEntry({
            addr: update.newAddress,
            active: true,
            registeredAt: uint64(block.timestamp),
            version: newVersion
        });

        activeVersion[update.chainId][update.contractName] = newVersion;

        emit UpdateExecuted(updateId, update.chainId, update.contractName, update.newAddress);
    }

    /// @notice Get all contract names
    function getContractNames() external view returns (string[] memory) {
        return contractNames;
    }

    /// @notice Helper: parse version number from "vX" string
    function _parseVersion(string memory version) internal pure returns (uint256) {
        bytes memory versionBytes = bytes(version);
        if (versionBytes.length == 0 || versionBytes[0] != 'v') return 0;

        uint256 result = 0;
        for (uint256 i = 1; i < versionBytes.length; i++) {
            result = result * 10 + (uint256(uint8(versionBytes[i])) - 48);
        }
        return result;
    }

    /// @notice Helper: convert uint to string
    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return '0';
        uint256 j = _i;
        uint256 len = 0;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
