// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '../decentralized-resolution-module/IIncentiveModule.sol';
import '../types/EscrowTypes.sol';

/**
 * @title BondCollector
 * @notice External contract for collecting escalation bonds (ETH or ERC20)
 * @dev Extracted from BaseEscrow to reduce contract size (Priority 2 optimization)
 * 
 *      Handles:
 *      - ETH bond collection with protocol fee deduction
 *      - ERC20 bond collection with protocol fee deduction
 *      - Custody lives in this contract for ERC20 bonds (escrow transfers in, this contract approves incentive module)
 *      - Protocol fee transfer to fee address
 *      - Bond recording via incentive module
 */
contract BondCollector is AccessControl {
    using SafeERC20 for IERC20;

    // ============ Role Constants ============
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    
    // ============ Custom Errors ============
    error ZeroOwner();

    // Events
    event ProtocolFeeCollected(
        uint8 indexed kind, // 1 = appeal bond
        uint256 indexed workflowId,
        address indexed token,
        uint256 bondAmount,
        uint256 feeBps,
        uint256 feeAmount
    );

    /**
     * @notice Constructor for BondCollector
     * @param initialOwner Address that will receive DEFAULT_ADMIN_ROLE (for initial setup only)
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        // ROLE_TIMELOCK gates registerEscrowContract(), so initialOwner must have it for initial setup.
        _grantRole(ROLE_TIMELOCK, initialOwner);
    }

    /**
     * @notice Register an escrow contract (grants it ROLE_ESCROW_CONTRACT)
     * @param escrowContract Address of the escrow contract
     * @dev Only ROLE_TIMELOCK can register escrow contracts (governance-controlled)
     */
    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (escrowContract == address(0)) revert InvalidAddress('Escrow contract cannot be zero', escrowContract);
        _grantRole(ROLE_ESCROW_CONTRACT, escrowContract);
    }

    /**
     * @notice Collect escalation bond (ETH or ERC20) and deduct protocol fee
     * @param workflowId The escrow ID
     * @param incentiveMod Incentive module for bond recording
     * @param bondAmount Bond amount to collect
     * @param bondToken Bond token address (address(0) for ETH)
     * @param newLevel New escalation level
     * @param snapshottedBondFee Protocol fee in basis points (from module snapshot)
     * @param escrowFeeAddress Address to receive protocol fees
     * @param depositor Address that deposited the bond (user for ETH, this contract for ERC20)
     * @param escalatedBy Address that initiated the escalation (always the user)
     * @return collected Whether bond was successfully collected
     * @dev Only authorized escrow contracts can call this function
     */
    function collectBond(
        uint256 workflowId,
        IIncentiveModule incentiveMod,
        uint256 bondAmount,
        address bondToken,
        uint8 newLevel,
        uint256 snapshottedBondFee,
        address escrowFeeAddress,
        address depositor,
        address escalatedBy
    ) external payable onlyRole(ROLE_ESCROW_CONTRACT) returns (bool collected) {
        if (address(incentiveMod) == address(0)) return false;
        
        if (bondToken == address(0)) {
            // ETH bond
            uint256 ethToSend = bondAmount;
            if (msg.value > bondAmount) {
                ethToSend = bondAmount;
            }
            
            uint256 protocolFeeAmount = 0;
            if (snapshottedBondFee > 0 && escrowFeeAddress != address(0)) {
                protocolFeeAmount = (ethToSend * snapshottedBondFee) / 10000;
                if (protocolFeeAmount > 0) {
                    // Transfer protocol fee first - if it fails, revert to keep accounting clean
                    (bool feeSuccess, ) = payable(escrowFeeAddress).call{value: protocolFeeAmount}('');
                    if (!feeSuccess) {
                        return false; // Fee transfer failed
                    }
                    ethToSend = ethToSend - protocolFeeAmount;
                    emit ProtocolFeeCollected(1, workflowId, bondToken, bondAmount, snapshottedBondFee, protocolFeeAmount);
                }
            }
            
            if (ethToSend > 0) {
                // ETH bond: call payable function with ETH value
                // For ETH bonds, depositor = escalatedBy = user
                (bool s, ) = address(incentiveMod).call{value: ethToSend}(
                    abi.encodeWithSelector(
                        IIncentiveModule.recordAppealBond.selector,
                        workflowId,
                        depositor, // depositor (user for ETH)
                        escalatedBy, // escalatedBy (user)
                        ethToSend,
                        bondToken,
                        newLevel
                    )
                );
                return s;
            }
        } else {
            // ERC20 bond - custody is held by this contract
            // BaseEscrow transfers tokens to this contract before calling collectBond
            // Step 1: Calculate and transfer protocol fee
            uint256 protocolFeeAmount = 0;
            uint256 bondToRecord = bondAmount;
            
            if (snapshottedBondFee > 0 && escrowFeeAddress != address(0)) {
                protocolFeeAmount = (bondAmount * snapshottedBondFee) / 10000;
                if (protocolFeeAmount > 0) {
                    bondToRecord = bondAmount - protocolFeeAmount;
                    IERC20(bondToken).safeTransfer(escrowFeeAddress, protocolFeeAmount);
                    emit ProtocolFeeCollected(1, workflowId, bondToken, bondAmount, snapshottedBondFee, protocolFeeAmount);
                }
            }
            
            // Step 2: Approve incentive module to pull remaining tokens
            if (bondToRecord > 0) {
                // Pull-based pattern: approve incentive module to pull tokens
                // If recordAppealBond fails, tokens remain with this contract (no loss)
                IERC20(bondToken).safeIncreaseAllowance(address(incentiveMod), bondToRecord);
                try incentiveMod.recordAppealBond(workflowId, depositor, escalatedBy, bondToRecord, bondToken, newLevel) {
                    // Reset approval to zero after successful call
                    IERC20(bondToken).approve(address(incentiveMod), 0);
                    return true;
                } catch {
                    // Reset approval on failure
                    IERC20(bondToken).approve(address(incentiveMod), 0);
                    return false;
                }
            }
        }
        return false;
    }
}
