// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IYieldGenerationModule} from '../interfaces/IYieldGenerationModule.sol';
import {EscrowSettings} from '../types/EscrowTypes.sol';
import {AaveYieldHandlingLibrary} from '../libraries/AaveYieldHandlingLibrary.sol';
import {InvariantGuardInternal} from './InvariantGuardInternal.sol';

/**
 * @title InvariantGuardedAaveYieldLibrary
 * @notice Singleton yield library with InvariantGuard protection for delegatecall pattern
 * @dev 
 *      This contract provides a security-enhanced alternative to the module pattern.
 *      It uses delegatecall to execute Aave operations in the context of the calling
 *      escrow contract, with invariant guards to prevent malicious storage modifications.
 *      
 *      KEY DIFFERENCES FROM MODULE PATTERN:
 *      - Singleton: One library instance serves MULTIPLE escrow contracts
 *      - Delegatecall: Executes in caller's storage context (not separate module storage)
 *      - InvariantGuard: Prevents unauthorized storage modifications during delegatecall
 *      
 *      ARCHITECTURE:
 *      - EscrowVault calls this library via delegatecall
 *      - Library executes Aave operations in EscrowVault's context
 *      - InvariantGuard validates no critical storage was modified
 *      
 *      SECURITY:
 *      - Protects: owner, pendingOwner, guardian, pendingGuardian, module pointers, feeAddress
 *      - Prevents: Ownership theft, module hijacking, fee manipulation via delegatecall
 *      
 *      VERSION: 1.0.0
 *      - First version of InvariantGuard-protected yield library
 *      - Follows semantic versioning for library releases
 */
abstract contract InvariantGuardedAaveYieldLibrary is InvariantGuardInternal {
    using AaveYieldHandlingLibrary for *;

    /**
     * @notice Library identification
     */
    string public constant LIBRARY_NAME = "InvariantGuardedAaveYieldLibrary";
    string public constant LIBRARY_VERSION = "1.0.0";
    bytes32 public constant PROTOCOL_ID = keccak256("aave-v3-guarded");

    /**
     * @notice Get library metadata
     * @return name Library name
     * @return version Library version (semantic versioning)
     * @return protocolId Protocol identifier
     */
    function getLibraryInfo()
        external
        pure
        returns (string memory name, string memory version, bytes32 protocolId)
    {
        return (LIBRARY_NAME, LIBRARY_VERSION, PROTOCOL_ID);
    }

    /**
     * @notice Get the critical storage slots that are protected by invariant guards
     * @return slots Array of protected storage slot positions
     * @dev These slots are validated before/after delegatecall to prevent tampering
     */
    function getProtectedSlots() external pure returns (bytes32[] memory slots) {
        return _getAllCriticalSlots();
    }

    /**
     * @notice Get owner-related storage slots (slots 0 and 1 in Ownable)
     * @return slots Array containing owner slot positions
     */
    function getOwnerSlots() external pure returns (bytes32[] memory slots) {
        return _getOwnerSlots();
    }

    /**
     * @notice Get module-related storage slots
     * @return slots Array containing module pointer slot positions
     */
    function getModuleSlots() external pure returns (bytes32[] memory slots) {
        return _getModuleSlots();
    }

    function _getOwnerSlots() internal pure returns (bytes32[] memory slots) {
        slots = new bytes32[](2);
        slots[0] = bytes32(uint256(0));
        slots[1] = bytes32(uint256(1));
    }

    function _getModuleSlots() internal pure returns (bytes32[] memory slots) {
        slots = new bytes32[](3);
        slots[0] = bytes32(keccak256('yieldGenerationModule'));
        slots[1] = bytes32(keccak256('yieldDistributionModule'));
        slots[2] = bytes32(keccak256('feeAddress'));
    }

    function _getAllCriticalSlots() internal pure returns (bytes32[] memory slots) {
        bytes32[] memory ownerSlots = _getOwnerSlots();
        bytes32[] memory moduleSlots = _getModuleSlots();

        slots = new bytes32[](ownerSlots.length + moduleSlots.length);

        for (uint256 i = 0; i < ownerSlots.length; i++) {
            slots[i] = ownerSlots[i];
        }
        for (uint256 i = 0; i < moduleSlots.length; i++) {
            slots[ownerSlots.length + i] = moduleSlots[i];
        }
    }

    /**
     * @notice Execute guarded yield withdrawal via delegatecall
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amount Principal amount to withdraw
     * @param genModule Yield generation module
     * @param settings Escrow settings
     * @param scaledShares Current scaled shares for this escrow
     * @param aaveYieldLibrary Aave yield library address (for delegatecall)
     * @return result Withdrawal result with actual amount and success status
     * 
     * @dev Protects critical storage slots from modification during delegatecall
     *      If the delegated code tries to modify owner/module/fee slots, transaction reverts
     */
    function guardedYieldWithdrawal(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        uint256 scaledShares,
        address aaveYieldLibrary
    ) internal returns (AaveYieldHandlingLibrary.WithdrawalResult memory) {
        bytes32[] memory protectedSlots = _getAllCriticalSlots();

        return
            _guardedYieldWithdrawal(
                workflowId,
                token,
                amount,
                genModule,
                settings,
                scaledShares,
                aaveYieldLibrary,
                protectedSlots
            );
    }

    function _guardedYieldWithdrawal(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        uint256 scaledShares,
        address aaveYieldLibrary,
        bytes32[] memory protectedSlots
    )
        internal
        invariantStorage(protectedSlots)
        returns (AaveYieldHandlingLibrary.WithdrawalResult memory)
    {
        return
            AaveYieldHandlingLibrary.handleYieldWithdrawal(
                workflowId,
                token,
                amount,
                genModule,
                settings,
                scaledShares,
                aaveYieldLibrary
            );
    }

    /**
     * @notice Execute guarded yield deposit via delegatecall
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amount Amount to deposit for yield
     * @param genModule Yield generation module
     * @param settings Escrow settings
     * @param aaveYieldLibrary Aave yield library address (for delegatecall)
     * @return result Deposit result with scaled shares and success status
     * 
     * @dev Protects critical storage slots from modification during delegatecall
     *      If the delegated code tries to modify owner/module/fee slots, transaction reverts
     */
    function guardedYieldDeposit(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        address aaveYieldLibrary
    ) internal returns (AaveYieldHandlingLibrary.DepositResult memory) {
        bytes32[] memory protectedSlots = _getAllCriticalSlots();

        return
            _guardedYieldDeposit(
                workflowId,
                token,
                amount,
                genModule,
                settings,
                aaveYieldLibrary,
                protectedSlots
            );
    }

    function _guardedYieldDeposit(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        address aaveYieldLibrary,
        bytes32[] memory protectedSlots
    )
        internal
        invariantStorage(protectedSlots)
        returns (AaveYieldHandlingLibrary.DepositResult memory)
    {
        return
            AaveYieldHandlingLibrary.handleYieldDeposit(
                workflowId,
                token,
                amount,
                genModule,
                settings,
                aaveYieldLibrary
            );
    }
}
