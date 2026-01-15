// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/introspection/IERC165.sol';

/**
 * @title IFraudProofModule
 * @notice Interface for fraud proof module (DR v3 placeholder)
 * @dev ⚠️ DR v3 placeholder - Not implemented in v1/v2
 *      This interface is provided for future module swaps when DR v3 is deployed.
 *      Fraud lane is explicitly excluded from DR v1 and DR v2.
 *      Implementation is guarded behind module swap via slow lane governance.
 * @dev Fraud lane provides investigation + execution path for fraud proofs.
 *      Used when objective evidence of fraud is available.
 * @dev All resolution modules must implement ERC-165 for interface detection
 */
interface IFraudProofModule is IERC165 {
    /**
     * @notice Submit a fraud proof for investigation
     * @param workflowId The escrow transfer ID
     * @param proof The fraud proof data (structured evidence)
     * @return submissionId The fraud proof submission ID
     * @dev In DR v3, fraud proofs trigger investigation + execution path
     */
    function submitFraudProof(
        uint256 workflowId,
        bytes calldata proof
    ) external returns (uint256 submissionId);

    /**
     * @notice Verify a fraud proof
     * @param workflowId The escrow transfer ID
     * @return isValid True if fraud proof is valid
     * @dev In DR v3, fraud proofs must be objectively verifiable
     */
    function verifyFraudProof(uint256 workflowId) external view returns (bool isValid);

    /**
     * @notice Get the status of a fraud proof submission
     * @param submissionId The fraud proof submission ID
     * @return status The submission status (pending, verified, rejected, executed)
     * @return workflowId The associated escrow transfer ID
     */
    function getFraudProofStatus(
        uint256 submissionId
    ) external view returns (uint8 status, uint256 workflowId);

    /**
     * @notice Execute fraud proof resolution (if verified)
     * @param submissionId The fraud proof submission ID
     * @return success True if execution was successful
     * @dev In DR v3, verified fraud proofs trigger automatic resolution execution
     */
    function executeFraudProof(uint256 submissionId) external returns (bool success);

    /**
     * @notice Get the module name/identifier
     * @return name The module name
     */
    function moduleName() external pure returns (string memory name);

    /**
     * @notice Get the module version
     * @return version The module version (semantic versioning, e.g., "3.0.0")
     */
    function moduleVersion() external pure returns (string memory version);
}
