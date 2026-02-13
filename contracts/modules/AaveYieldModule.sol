// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../interfaces/IYieldModule.sol';
import '../interfaces/aave/AaveV3Interfaces.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/**
 * @title AaveYieldModule
 * @notice Simplified Aave V3 yield module implementing IYieldModule v2.5
 * 
 * This module is responsible for:
 * - Depositing tokens into Aave V3
 * - Tracking positions by (escrow, escrowId)
 * - Withdrawing from Aave and returning to escrow
 * - Emergency recovery on normal withdrawal failure
 * 
 * The escrow is responsible for:
 * - Initializing yield (calling initializeYield)
 * - Computing yield amounts and distribution
 * - Handling all authorization and fund flow
 * 
 * This separation keeps modules simple and distribution policy in core.
 */
contract AaveYieldModule is IYieldModule {
    using SafeERC20 for IERC20;
    
    // ============ Types ============
    
    struct YieldPosition {
        address token;
        uint256 principalDeposited;  // INVARIANT 4: actual accepted amount, not requested
    }
    
    // ============ Storage ============
    
    // Aave pool reference
    IAavePool public immutable aavePool;
    
    // Module metadata
    string public constant MODULE_NAME = "AaveYieldModule";
    string public constant MODULE_VERSION = "2.5.0";
    bytes32 public constant PROTOCOL_ID = keccak256("aave-v3");
    
    // Authorization: approved escrow contracts
    mapping(address escrow => bool) public approvedEscrows;
    
    // Position tracking: (escrow => (escrowId => position))
    mapping(address escrow => mapping(uint256 escrowId => YieldPosition)) public positions;
    
    // Token to aToken mapping (Aave V3 reserve configuration)
    // Must be set by governance/admin before tokens can be deposited
    mapping(address token => address aToken) public tokenToAToken;
    
    // ============ Events ============
    
    event EscrowApproved(address indexed escrow);
    event EscrowRevoked(address indexed escrow);
    event TokenConfigured(address indexed token, address indexed aToken);
    
    // ============ Constructor ============
    
    constructor(address _aavePool) {
        require(_aavePool != address(0), "InvalidPoolAddress");
        require(_aavePool.code.length > 0, "PoolAddressIsNotContract");
        aavePool = IAavePool(_aavePool);
    }
    
    // ============ Authorization ============
    
    modifier onlyEscrow() {
        require(approvedEscrows[msg.sender], "UnauthorizedEscrow");
        _;
    }
    
    /**
     * @notice Approve an escrow contract to use this module
     * @param escrow Address to approve
     */
    function approveEscrow(address escrow) external {
        require(escrow != address(0), "InvalidAddress");
        approvedEscrows[escrow] = true;
        emit EscrowApproved(escrow);
    }
    
    /**
     * @notice Revoke approval for an escrow contract
     * @param escrow Address to revoke
     */
    function revokeEscrow(address escrow) external {
        approvedEscrows[escrow] = false;
        emit EscrowRevoked(escrow);
    }
    
    /**
     * @notice Configure aToken address for a token (must be called before deposits)
     * @param token Underlying token address
     * @param aToken Aave aToken address for this underlying
     */
    function configureToken(address token, address aToken) external {
        require(token != address(0), "InvalidAddress");
        require(aToken != address(0), "InvalidAToken");
        tokenToAToken[token] = aToken;
        emit TokenConfigured(token, aToken);
    }
    
    // ============ Core Yield Operations ============
    
    /**
     * @notice Initialize yield position in Aave
     * @param escrowId Escrow identifier
     * @param token Token to deposit
     * @param amount Amount to deposit
     * @param yieldMode Yield preset (currently unused, for future flexibility)
     * @return accepted Amount actually deposited
     * 
     * INVARIANT 4: We track principalDeposited (actual accepted), not requested amount
     * This handles fee-on-transfer tokens and ensures yield calculation is correct
     */
    function initializeYield(
        uint256 escrowId,
        address token,
        uint256 amount,
        YieldPreset yieldMode
    ) external onlyEscrow returns (uint256 accepted) {
        require(amount > 0, "ZeroAmount");
        
        // Escrow has already transferred 'amount' to us (push model)
        // Verify we have the balance
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        require(balBefore >= amount, "InsufficientBalance");
        
        // Deposit to Aave
        aavePool.supply(token, amount, address(this), 0);
        
        // Calculate actual deposited (handles fee-on-transfer)
        uint256 balAfter = IERC20(token).balanceOf(address(this));
        uint256 actualDeposited = balBefore - balAfter;
        
        // Store position with actual deposited amount (INVARIANT 4)
        positions[msg.sender][escrowId] = YieldPosition({
            token: token,
            principalDeposited: actualDeposited
        });
        
        emit YieldInitialized(escrowId, token, actualDeposited, yieldMode);
        
        return actualDeposited;
    }
    
    /**
     * @notice Withdraw yield position from Aave
     * @param escrowId Escrow identifier
     * @param token Token to withdraw
     * @param principalExpected Expected principal (for validation)
     * @return principalOut Principal amount
     * @return yieldOut Yield amount
     * 
     * INVARIANT 5: Escrow will do delta check (balBefore/balAfter) to verify funds
     */
    function unwindToEscrow(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external onlyEscrow returns (uint256 principalOut, uint256 yieldOut) {
        YieldPosition memory pos = positions[msg.sender][escrowId];
        require(pos.token == token, "TokenMismatch");
        
        // Get current aToken balance (represents principal + yield)
        address aToken = _getAToken(token);
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
        require(aTokenBalance > 0, "NoPosition");
        
        // Withdraw everything from Aave back to us
        // Note: Aave will transfer underlying token and burn aTokens
        uint256 totalReceived = aavePool.withdraw(token, aTokenBalance, address(this));
        
        // Transfer everything back to escrow (msg.sender)
        // INVARIANT 2: Only send to msg.sender (the escrow)
        IERC20(token).safeTransfer(msg.sender, totalReceived);
        
        // Calculate yield
        // INVARIANT 4: Use principalDeposited (actual accepted), not principalExpected
        uint256 principal = pos.principalDeposited;
        uint256 yield = totalReceived > principal ? totalReceived - principal : 0;
        
        // Clean up position
        delete positions[msg.sender][escrowId];
        
        emit YieldWithdrawn(escrowId, token, principal, yield);
        
        return (principal, yield);
    }
    
    /**
     * @notice Emergency recovery if normal unwind fails
     * @param escrowId Escrow identifier
     * @param token Token to recover
     * @param principalExpected Expected principal
     * @return recovered Amount recovered
     * 
     * INVARIANT 1: MUST return funds or REVERT
     * INVARIANT 6: Strict semantics - return > 0 or revert, never return 0
     */
    function emergencyUnwind(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external onlyEscrow returns (uint256 recovered) {
        YieldPosition memory pos = positions[msg.sender][escrowId];
        require(pos.token == token, "TokenMismatch");
        
        // Get aToken balance
        address aToken = _getAToken(token);
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
        
        // If no aToken balance, funds are already gone
        if (aTokenBalance == 0) {
            revert("NoATokenBalance");
        }
        
        // Try to withdraw
        uint256 out = aavePool.withdraw(token, aTokenBalance, address(this));
        
        // Transfer to escrow
        IERC20(token).safeTransfer(msg.sender, out);
        
        // Clean up
        delete positions[msg.sender][escrowId];
        
        // INVARIANT 6: Strict semantics - never return 0
        if (out == 0) {
            revert("EmergencyUnwindReturnedZero");
        }
        
        emit EmergencyUnwindExecuted(escrowId, token, out, keccak256("emergency_unwind"));
        
        return out;
    }
    
    // ============ Metadata ============
    
    /**
     * @notice Check if module can handle this token/amount
     * @param token Token to check
     * @param mode Yield mode
     * @param amount Amount to deposit
     * @return supported Whether supported
     * @return reasonCode Error code (0x0 = OK)
     */
    function canHandle(
        address token,
        YieldPreset mode,
        uint256 amount
    ) external view returns (bool supported, bytes32 reasonCode) {
        // For now, we trust Aave pool integration
        // A more robust implementation would query Aave's reserve configuration
        // but that requires more complex DataTypes imports
        // For v2.5, we rely on initializeYield to fail cleanly if token is unsupported
        return (true, 0x0);
    }
    
    /**
     * @notice Get module metadata
     * @return name Module name
     * @return version Module version
     * @return protocolId Protocol identifier
     */
    function getModuleInfo()
        external pure returns (string memory name, string memory version, bytes32 protocolId) {
        return (MODULE_NAME, MODULE_VERSION, PROTOCOL_ID);
    }
    
    // ============ Helpers ============
    
    /**
     * @notice Get aToken address for underlying token
     * @param token Underlying token
     * @return aToken AToken address
     */
    function _getAToken(address token) internal view returns (address aToken) {
        aToken = tokenToAToken[token];
        require(aToken != address(0), "TokenNotConfigured");
        return aToken;
    }
}
