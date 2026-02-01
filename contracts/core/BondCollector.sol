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
        if (escrowContract == address(0)) revert InvalidAddress(ADDR_ESCROW_CONTRACT, escrowContract);
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
            return _collectETHBond(workflowId, incentiveMod, bondAmount, newLevel, snapshottedBondFee, escrowFeeAddress, depositor, escalatedBy);
        } else {
            return _collectERC20Bond(workflowId, incentiveMod, bondAmount, bondToken, newLevel, snapshottedBondFee, escrowFeeAddress, depositor, escalatedBy);
        }
    }

    /**
     * @notice Internal function to handle ETH bond collection
     */
    function _collectETHBond(
        uint256 workflowId,
        IIncentiveModule incentiveMod,
        uint256 bondAmount,
        uint8 newLevel,
        uint256 snapshottedBondFee,
        address escrowFeeAddress,
        address depositor,
        address escalatedBy
    ) internal returns (bool) {
        uint256 ethToSend = bondAmount;
        if (msg.value > bondAmount) {
            ethToSend = bondAmount;
        }
        
        if (snapshottedBondFee > 0 && escrowFeeAddress != address(0)) {
            uint256 protocolFeeAmount = (ethToSend * snapshottedBondFee) / 10000;
            if (protocolFeeAmount > 0) {
                (bool feeSuccess, ) = payable(escrowFeeAddress).call{value: protocolFeeAmount}('');
                if (!feeSuccess) return false;
                ethToSend = ethToSend - protocolFeeAmount;
                emit ProtocolFeeCollected(1, workflowId, address(0), bondAmount, snapshottedBondFee, protocolFeeAmount);
            }
        }
        
        if (ethToSend > 0) {
            (bool s, ) = address(incentiveMod).call{value: ethToSend}(
                abi.encodeWithSelector(
                    IIncentiveModule.recordAppealBond.selector,
                    workflowId,
                    depositor,
                    escalatedBy,
                    ethToSend,
                    address(0),
                    newLevel
                )
            );
            return s;
        }
        return false;
    }

    /**
     * @notice Internal function to handle ERC20 bond collection
     */
    function _collectERC20Bond(
        uint256 workflowId,
        IIncentiveModule incentiveMod,
        uint256 bondAmount,
        address bondToken,
        uint8 newLevel,
        uint256 snapshottedBondFee,
        address escrowFeeAddress,
        address depositor,
        address escalatedBy
    ) internal returns (bool) {
        // CRIT-3: Actually pull the tokens from the caller
        IERC20(bondToken).safeTransferFrom(_msgSender(), address(this), bondAmount);

        uint256 bondToRecord = bondAmount;
        
        if (snapshottedBondFee > 0 && escrowFeeAddress != address(0)) {
            uint256 protocolFeeAmount = (bondAmount * snapshottedBondFee) / 10000;
            if (protocolFeeAmount > 0) {
                bondToRecord = bondAmount - protocolFeeAmount;
                IERC20(bondToken).safeTransfer(escrowFeeAddress, protocolFeeAmount);
                emit ProtocolFeeCollected(1, workflowId, bondToken, bondAmount, snapshottedBondFee, protocolFeeAmount);
            }
        }
        
        if (bondToRecord > 0) {
            IERC20(bondToken).safeIncreaseAllowance(address(incentiveMod), bondToRecord);
            try incentiveMod.recordAppealBond(workflowId, depositor, escalatedBy, bondToRecord, bondToken, newLevel) {
                IERC20(bondToken).approve(address(incentiveMod), 0);
                return true;
            } catch {
                IERC20(bondToken).approve(address(incentiveMod), 0);
                return false;
            }
        }
        return false;
    }

    /**
     * @notice Approve a spender to pull ERC20 bond tokens
     * @dev Intended for escrow contract flows where the escrow contract calls the incentive module,
     *      but custody lives in this contract (BondCollector).
     */
    function approveBondSpender(
        address token,
        address spender,
        uint256 amount
    ) external onlyRole(ROLE_ESCROW_CONTRACT) {
        IERC20(token).safeIncreaseAllowance(spender, amount);
    }

    /**
     * @notice Reset an ERC20 approval back to zero
     * @dev Best practice to avoid leaving allowances lingering on third-party contracts.
     */
    function resetBondSpender(address token, address spender) external onlyRole(ROLE_ESCROW_CONTRACT) {
        IERC20(token).approve(spender, 0);
    }

    /**
     * @notice Recover ERC20 tokens sent to this contract by mistake
     */
    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external onlyRole(ROLE_TIMELOCK) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 recoveryAmount = amount == 0 ? balance : amount;
        if (recoveryAmount > balance) revert InvalidAmount(AMOUNT_GENERIC);
        IERC20(token).safeTransfer(recipient, recoveryAmount);
    }

    /**
     * @notice Recover native ETH sent to this contract by mistake
     */
    function recoverNativeETH(
        address recipient,
        uint256 amount
    ) external onlyRole(ROLE_TIMELOCK) {
        uint256 balance = address(this).balance;
        uint256 recoveryAmount = amount == 0 ? balance : amount;
        if (recoveryAmount > balance) revert InvalidAmount(AMOUNT_GENERIC);
        (bool success, ) = payable(recipient).call{value: recoveryAmount}("");
        if (!success) revert InvalidAddress(ADDR_RECIPIENT, recipient);
    }
}
