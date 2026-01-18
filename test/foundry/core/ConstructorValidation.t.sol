// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/EscrowableERC20.sol';
import '../../../contracts/core/BaseEscrow.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';

/**
 * @title ConstructorValidation
 * @notice Tests for constructor validation in EscrowVault and EscrowableERC20
 * @dev Ensures all constructor arguments are properly validated before deployment
 */
contract ConstructorValidation is Test {
    address public feeAddress;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public moduleManagement;

    uint256 public constant MAX_ESCROW_FEE_BPS = 200; // 2% maximum
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 3000; // 30% maximum
    uint256 public constant DEFAULT_YIELD_PROTOCOL_FEE_BPS = 3000; // 30% default

    function setUp() public {
        feeAddress = address(0xFEE);
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
    }

    // ============ EscrowVault Constructor Tests ============

    function test_EscrowVault_constructor_reverts_escrowFeeTooHigh() public {
        uint256 invalidFee = MAX_ESCROW_FEE_BPS + 1;
        
        vm.expectRevert(
            abi.encodeWithSignature('InvalidEscrowFee(uint256,uint256)', invalidFee, MAX_ESCROW_FEE_BPS)
        );
        
        new EscrowVault(
            invalidFee,
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
    }

    function test_EscrowVault_constructor_succeeds_escrowFeeZero() public {
        EscrowVault vault = new EscrowVault(
            0,
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
        
        assertEq(vault.escrowFee(), 0);
    }

    function test_EscrowVault_constructor_succeeds_escrowFeeMax() public {
        EscrowVault vault = new EscrowVault(
            MAX_ESCROW_FEE_BPS,
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
        
        assertEq(vault.escrowFee(), MAX_ESCROW_FEE_BPS);
    }

    function test_EscrowVault_constructor_reverts_zeroFeeAddress() public {
        vm.expectRevert(abi.encodeWithSignature('ZeroAddress(uint8)', 1));
        
        new EscrowVault(
            100,
            address(0),
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
    }

    function test_EscrowVault_constructor_reverts_zeroYieldOpsAddress() public {
        vm.expectRevert(abi.encodeWithSignature('ZeroAddress(uint8)', 2));
        
        new EscrowVault(
            100,
            feeAddress,
            address(0),
            address(disputeOps),
            address(moduleManagement)
        );
    }

    function test_EscrowVault_constructor_reverts_zeroDisputeOpsAddress() public {
        vm.expectRevert(abi.encodeWithSignature('ZeroAddress(uint8)', 3));
        
        new EscrowVault(
            100,
            feeAddress,
            address(yieldOps),
            address(0),
            address(moduleManagement)
        );
    }

    function test_EscrowVault_constructor_succeeds_validParameters() public {
        EscrowVault vault = new EscrowVault(
            100, // 1%
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
        
        assertEq(vault.escrowFee(), 100);
        assertEq(vault.escrowFeeAddress(), feeAddress);
        assertEq(vault.yieldProtocolFeeBps(), DEFAULT_YIELD_PROTOCOL_FEE_BPS);
        assertEq(vault.appealBondProtocolFeeBps(), 0);
    }

    function test_EscrowVault_constructor_protocolFeeInitialized() public {
        EscrowVault vault = new EscrowVault(
            100,
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
        
        // Verify protocol fees are initialized correctly
        assertEq(vault.yieldProtocolFeeBps(), DEFAULT_YIELD_PROTOCOL_FEE_BPS);
        assertEq(vault.appealBondProtocolFeeBps(), 0);
        
        // Verify they don't exceed maximum
        assertLe(vault.yieldProtocolFeeBps(), MAX_PROTOCOL_FEE_BPS);
        assertLe(vault.appealBondProtocolFeeBps(), MAX_PROTOCOL_FEE_BPS);
    }

    // ============ EscrowableERC20 Constructor Tests ============

    function test_EscrowableERC20_constructor_reverts_escrowFeeTooHigh() public {
        uint256 invalidFee = MAX_ESCROW_FEE_BPS + 1;
        
        vm.expectRevert(
            abi.encodeWithSignature('InvalidEscrowFee(uint256,uint256)', invalidFee, MAX_ESCROW_FEE_BPS)
        );
        
        new EscrowableERC20(
            'Test Token',
            'TEST',
            invalidFee,
            feeAddress,
            address(yieldOps),
            address(disputeOps)
        );
    }

    function test_EscrowableERC20_constructor_succeeds_escrowFeeZero() public {
        EscrowableERC20 token = new EscrowableERC20(
            'Test Token',
            'TEST',
            0,
            feeAddress,
            address(yieldOps),
            address(disputeOps)
        );
        
        assertEq(token.escrowFee(), 0);
    }

    function test_EscrowableERC20_constructor_succeeds_escrowFeeMax() public {
        EscrowableERC20 token = new EscrowableERC20(
            'Test Token',
            'TEST',
            MAX_ESCROW_FEE_BPS,
            feeAddress,
            address(yieldOps),
            address(disputeOps)
        );
        
        assertEq(token.escrowFee(), MAX_ESCROW_FEE_BPS);
    }

    function test_EscrowableERC20_constructor_reverts_zeroFeeAddress() public {
        vm.expectRevert(
            abi.encodeWithSignature('InvalidAddress(uint8,address)', 5, address(0))
        );
        
        new EscrowableERC20(
            'Test Token',
            'TEST',
            100,
            address(0),
            address(yieldOps),
            address(disputeOps)
        );
    }

    function test_EscrowableERC20_constructor_reverts_zeroYieldOpsAddress() public {
        vm.expectRevert(
            abi.encodeWithSignature('InvalidAddress(uint8,address)', 6, address(0))
        );
        
        new EscrowableERC20(
            'Test Token',
            'TEST',
            100,
            feeAddress,
            address(0),
            address(disputeOps)
        );
    }

    function test_EscrowableERC20_constructor_reverts_zeroDisputeOpsAddress() public {
        vm.expectRevert(
            abi.encodeWithSignature('InvalidAddress(uint8,address)', 7, address(0))
        );
        
        new EscrowableERC20(
            'Test Token',
            'TEST',
            100,
            feeAddress,
            address(yieldOps),
            address(0)
        );
    }

    function test_EscrowableERC20_constructor_succeeds_validParameters() public {
        EscrowableERC20 token = new EscrowableERC20(
            'Test Token',
            'TEST',
            100, // 1%
            feeAddress,
            address(yieldOps),
            address(disputeOps)
        );
        
        assertEq(token.escrowFee(), 100);
        assertEq(token.escrowFeeAddress(), feeAddress);
        assertEq(token.yieldProtocolFeeBps(), DEFAULT_YIELD_PROTOCOL_FEE_BPS);
        assertEq(token.appealBondProtocolFeeBps(), 0);
    }

    // ============ Fuzz Tests ============

    function test_EscrowVault_constructor_fuzz_validRange(uint256 feeBps) public {
        // Bound fee to valid range (0 to MAX_ESCROW_FEE_BPS)
        feeBps = bound(feeBps, 0, MAX_ESCROW_FEE_BPS);
        
        EscrowVault vault = new EscrowVault(
            feeBps,
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
        
        assertEq(vault.escrowFee(), feeBps);
    }

    function test_EscrowVault_constructor_fuzz_invalidRange(uint256 feeBps) public {
        // Bound fee to invalid range (above MAX_ESCROW_FEE_BPS)
        feeBps = bound(feeBps, MAX_ESCROW_FEE_BPS + 1, type(uint256).max);
        
        vm.expectRevert(
            abi.encodeWithSignature('InvalidEscrowFee(uint256,uint256)', feeBps, MAX_ESCROW_FEE_BPS)
        );
        
        new EscrowVault(
            feeBps,
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
    }

    function test_EscrowableERC20_constructor_fuzz_validRange(uint256 feeBps) public {
        // Bound fee to valid range (0 to MAX_ESCROW_FEE_BPS)
        feeBps = bound(feeBps, 0, MAX_ESCROW_FEE_BPS);
        
        EscrowableERC20 token = new EscrowableERC20(
            'Test Token',
            'TEST',
            feeBps,
            feeAddress,
            address(yieldOps),
            address(disputeOps)
        );
        
        assertEq(token.escrowFee(), feeBps);
    }
}
