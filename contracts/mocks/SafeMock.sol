// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SafeMock
 * @notice Mock Safe multisig for testing purposes
 * @dev Simulates a Safe multisig wallet with configurable owners and threshold
 * 
 * This is a simplified mock for testing. In production, use the real Safe contracts.
 */
contract SafeMock is Ownable {
    address[] public owners;
    uint256 public threshold;
    
    mapping(address => bool) private _isOwner;
    
    event SafeSetup(address[] owners, uint256 threshold);
    event ExecutionSuccess(bytes32 txHash);
    event ExecutionFailure(bytes32 txHash);
    
    /**
     * @notice Deploy SafeMock with owners and threshold
     * @param _owners Array of owner addresses
     * @param _threshold Number of signatures required
     */
    constructor(address[] memory _owners, uint256 _threshold) Ownable(msg.sender) {
        require(_owners.length > 0, "SafeMock: No owners");
        require(_threshold > 0 && _threshold <= _owners.length, "SafeMock: Invalid threshold");
        
        owners = _owners;
        threshold = _threshold;
        
        for (uint256 i = 0; i < _owners.length; i++) {
            require(_owners[i] != address(0), "SafeMock: Invalid owner");
            _isOwner[_owners[i]] = true;
        }
        
        emit SafeSetup(_owners, _threshold);
    }
    
    /**
     * @notice Execute a transaction (simplified - always succeeds in mock)
     * @param to Target address
     * @param value ETH value
     * @param data Call data
     * @param operation Operation type (0 = call, 1 = delegatecall)
     * @return success Whether execution succeeded
     */
    function execTransaction(
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation
    ) external returns (bool success) {
        require(_isOwner[msg.sender], "SafeMock: Not an owner");
        
        bytes32 txHash = keccak256(abi.encodePacked(to, value, data, operation, block.timestamp));
        
        // In real Safe, this would check signatures
        // For mock, we just execute if called by owner
        (success, ) = to.call{value: value}(data);
        
        if (success) {
            emit ExecutionSuccess(txHash);
        } else {
            emit ExecutionFailure(txHash);
        }
        
        return success;
    }
    
    /**
     * @notice Get owners array
     * @return Array of owner addresses
     */
    function getOwners() external view returns (address[] memory) {
        return owners;
    }
    
    /**
     * @notice Check if address is an owner
     * @param owner Address to check
     * @return Whether address is an owner
     */
    function isOwner(address owner) external view returns (bool) {
        return _isOwner[owner];
    }
}

