// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import './BaseEscrow.sol';
import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import './ModuleSnapshotRegistry.sol';
import '../libraries/ModuleGetterLibrary.sol';
import '../libraries/ModuleGetterConsolidationLibrary.sol';

/**
 * @title EscrowableERC20
 */
contract EscrowableERC20 is ERC20, BaseEscrow {
    using SafeERC20 for IERC20;
    uint256 public constant INITIAL_SUPPLY = 1000000000000000000000000;
    uint256 public totalHeldInEscrow = 0;
    uint256 public totalFees = 0;
    ModuleSnapshotRegistry public immutable moduleManagement;

    event FeesWithdrawn(uint256 amount);

    constructor(
        string memory name,
        string memory symbol,
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) ERC20(name, symbol) {
        if (escrowFeeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(escrowFeeBps, MAX_ESCROW_FEE_BPS);
        if (feeAddress == address(0)) revert ZeroAddress(1);
        if (yieldOpsAddress == address(0)) revert ZeroAddress(2);
        if (disputeOpsAddress == address(0)) revert ZeroAddress(3);
        if (moduleManagementAddress == address(0)) revert ZeroAddress(4);
        if (yieldOpsAddress.code.length == 0) revert ZeroAddress(2);
        if (disputeOpsAddress.code.length == 0) revert ZeroAddress(3);
        if (moduleManagementAddress.code.length == 0) revert ZeroAddress(4);

        escrowFee = escrowFeeBps;
        escrowFeeAddress = feeAddress;
        yieldOps = YieldOps(yieldOpsAddress);
        disputeOps = DisputeOps(disputeOpsAddress);
        moduleManagement = ModuleSnapshotRegistry(moduleManagementAddress);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ROLE_TIMELOCK, _msgSender());

        yieldProtocolFeeBps = DEFAULT_YIELD_PROTOCOL_FEE_BPS;
        appealBondProtocolFeeBps = 0;
        timeoutConfig.defaultAutoReleaseDelay = 0;
        timeoutConfig.defaultAutoCancelDelay = 0;
        timeoutConfig.maxDisputeDuration = 90 days;
        timeoutConfig.appealWindowDuration = 2 days;
        
        _mint(_msgSender(), INITIAL_SUPPLY);
    }

    // ============ Convenience Functions ============

    /**
     * @notice Create a new escrow with custom auto-release or auto-cancel time
     * @param seller Recipient address (seller)
     * @param amount Total amount to escrow (after fee deduction)
     * @param autoReleaseTime Timestamp for automatic release (0 = no auto-release)
     * @param autoCancelTime Timestamp for automatic cancel (0 = no auto-cancel)
     * @return workflowId The ID of the created escrow transfer
     */
    function createEscrow(
        address seller,
        uint256 amount,
        uint256 autoReleaseTime,
        uint256 autoCancelTime
    ) public returns (uint256) {
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            releaseAddress: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: autoReleaseTime,
            autoCancelTime: autoCancelTime
        });
        return createEscrow(address(this), seller, amount, settings);
    }

    function releaseEscrowTransfer(uint256 workflowId) public nonReentrant {
        _requirePending(workflowId);
        if (escrowTransfers[workflowId].from != _msgSender()) revert NotSender(workflowId, _msgSender(), escrowTransfers[workflowId].from);
        _releaseEscrowTransfer(workflowId);
    }

    // ============ BaseEscrow Hook Implementations ============

    /// @dev Token must be address(this)
    modifier onlyThisToken(address token) {
        if (token != address(this)) revert InvalidAddress(ADDR_TOKEN, token);
        _;
    }

    /**
     * @dev Transfer tokens from sender to contract using ERC20's internal _transfer
     * @param token Token address (must be address(this) for EscrowableERC20)
     * @param from Sender address
     * @param amount Amount to transfer
     */
    function _pullTokens(address token, address from, uint256 amount) internal override onlyThisToken(token) {
        _transfer(from, address(this), amount);
    }

    /**
     * @dev Record fee in totalFees
     * @param token Must be address(this)
     * @param amount Fee amount
     */
    function _recordFee(address token, uint256 amount) internal override onlyThisToken(token) {
        uint256 currentFees = totalFees;
        if (amount > type(uint256).max - currentFees) {
            revert FeeOverflow();
        }
        totalFees = currentFees + amount;
    }

    /**
     * @dev Transfer tokens using ERC20's internal _transfer
     * @param token Token address (must be address(this) for EscrowableERC20)
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transferTokens(address token, address to, uint256 amount) internal override onlyThisToken(token) {
        _transfer(address(this), to, amount);
    }

    /**
     * @dev Update escrow balance tracking
     * @param token Must be address(this)
     * @param amount Amount to add/subtract
     * @param add True to add, false to subtract
     */
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal override onlyThisToken(token) {
        if (add) {
            totalHeldInEscrow += amount;
        } else {
            // CRIT-1: Prevent underflow that could break accounting
            if (totalHeldInEscrow < amount) {
                revert BalanceUnderflow(token, totalHeldInEscrow, amount);
            }
            totalHeldInEscrow -= amount;
        }
    }

    /**
     * @dev Emit EscrowTransferCreated event (without token parameter)
     */
    function _emitEscrowTransferCreated(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount
    ) internal pure override {
        workflowId; token; from; to; amount;
    }

    /**
     * @dev Emit EscrowTransferCancelled event (without token parameter)
     */
    function _emitEscrowTransferCancelled(
        uint256 workflowId,
        address token,
        address from,
        uint256 amount
    ) internal pure override {
        workflowId; token; from; amount;
    }

    /**
     * @dev Emit EscrowTransferReleased event (without token parameter)
     */
    function _emitEscrowTransferReleased(
        uint256 workflowId,
        address token,
        address to,
        uint256 amount
    ) internal pure override {
        workflowId; token; to; amount;
    }

    /**
     * @dev Delegate yield deposit to module
     */
    function _depositForYield(
        IYieldModule generationModule,
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal override {
        address moduleAddress = address(generationModule);
        uint256 currentAllowance = allowance(address(this), moduleAddress);
        if (currentAllowance < amount) {
            _approve(address(this), moduleAddress, type(uint256).max);
        }
        
        uint256 balBefore = balanceOf(address(this));
        uint256 accepted = generationModule.initializeYield(workflowId, token, amount, YieldPreset.OFF);
        uint256 balAfter = balanceOf(address(this));

        if (balBefore - balAfter < accepted) {
            revert AccountingDeficit(token, amount);
        }
        
        // Store v2.5 yield tracking data
        v25YieldModules[workflowId] = moduleAddress;
        v25YieldPrincipals[workflowId] = accepted;
    }

    // ============ Module Getters ============

    function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
        address moduleAddr = ModuleGetterLibrary.getModuleAddress(
            workflowId, ModuleType.RELEASE, moduleSnapshots, moduleManagement, address(this)
        );
        return ModuleGetterConsolidationLibrary.getReleaseStrategy(moduleAddr);
    }

    function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
        address moduleAddr = ModuleGetterLibrary.getModuleAddress(
            workflowId, ModuleType.RESOLUTION, moduleSnapshots, moduleManagement, address(this)
        );
        return ModuleGetterConsolidationLibrary.getResolutionModule(moduleAddr, disputeResolutionModule);
    }

    function _getYieldGenerationModule(uint256 workflowId) internal view override returns (IYieldModule) {
        address moduleAddr = ModuleGetterLibrary.getModuleAddress(
            workflowId, ModuleType.YIELD_GEN, moduleSnapshots, moduleManagement, address(this)
        );
        return ModuleGetterConsolidationLibrary.getYieldModule(moduleAddr);
    }

    function _getYieldDistributionModule(uint256 workflowId) internal view override returns (IYieldDistributionModule) {
        address moduleAddr = ModuleGetterLibrary.getModuleAddress(
            workflowId, ModuleType.YIELD_DIST, moduleSnapshots, moduleManagement, address(this)
        );
        return ModuleGetterConsolidationLibrary.getYieldDistributionModule(moduleAddr);
    }

    // ============ Fee Management ============

    /**
     * @notice Withdraw accumulated escrow fees
     * @return success True if withdrawal was successful
     * @dev Only the fee address can withdraw fees. Transfers all accumulated fees to the fee address.
     */
    function withdrawFees() public nonReentrant returns (bool) {
        if (_msgSender() != escrowFeeAddress) {
            revert NotFeeAddress(_msgSender(), escrowFeeAddress);
        }
        uint256 feeAmount = totalFees;
        if (feeAmount == 0) {
            revert NoFeesToWithdraw(address(this), feeAmount);
        }
        
        // Check balance before clearing state (checks-effects-interactions pattern)
        uint256 balance = balanceOf(address(this));
        if (balance < feeAmount) {
            revert InsufficientContractBalance(address(this), feeAmount, balance);
        }
        
        // Clear state AFTER successful transfer to prevent fee loss on failure
        // Note: If transfer fails, revert will restore state (Solidity 0.8+ automatic)
        _transfer(address(this), escrowFeeAddress, feeAmount);
        totalFees = 0;
        
        emit FeesWithdrawn(feeAmount);
        return true;
    }
}

/**
 * @title EscrowableERC20Factory
 * @notice Factory contract for creating new EscrowableERC20 instances
 * @dev Allows deployment of new EscrowableERC20 tokens with custom parameters
 */
contract EscrowableERC20Factory {
    /// @notice Create a new EscrowableERC20 token contract
    function createEscrowableERC20(
        string memory name,
        string memory symbol,
        uint256 escrowFee,
        address escrowFeeAddress,
        address yieldOps,
        address disputeOps,
        address moduleManagement
    ) public returns (address) {
        return
            address(
                new EscrowableERC20(
                    name,
                    symbol,
                    escrowFee,
                    escrowFeeAddress,
                    yieldOps,
                    disputeOps,
                    moduleManagement
                )
            );
    }
}
