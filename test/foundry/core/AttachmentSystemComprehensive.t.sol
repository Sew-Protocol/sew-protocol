// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {EscrowableERC20} from "../../../contracts/core/EscrowableERC20.sol";
import {EscrowVault} from "../../../contracts/core/EscrowVault.sol";
import {ERC20Mock} from "../../../contracts/mocks/ERC20Mock.sol";
import {DefaultResolutionModule} from "../../../contracts/core/modules/DefaultResolutionModule.sol";

/**
 * @title AttachmentSystemComprehensive
 * @notice Comprehensive tests for attachment system covering:
 *  - Adding attachments (URIs and hashes)
 *  - Attachment limits
 *  - Attachment validation
 *  - Attachment retrieval
 *  - Batch operations
 */
contract AttachmentSystemComprehensive is Test {
    EscrowableERC20 token;
    EscrowVault vault;
    ERC20Mock paymentToken;
    DefaultResolutionModule resolutionModule;
    
    address owner = address(this);
    address sender = address(0x1);
    address recipient = address(0x2);
    address resolver = address(0x3);
    address feeRecipient = address(0x4);
    
    uint256 constant ESCROW_FEE = 100;
    uint256 constant AMOUNT = 10 ether;
    
    bytes32 ROLE_TIMELOCK;
    
    function setUp() public {
        token = new EscrowableERC20("Test", "TST", ESCROW_FEE, feeRecipient, address(0));
        paymentToken = new ERC20Mock("Payment", "PAY", address(this), 1_000_000 ether);
        vault = new EscrowVault(ESCROW_FEE, feeRecipient, address(0));
        
        ROLE_TIMELOCK = token.ROLE_TIMELOCK();
        token.grantRole(ROLE_TIMELOCK, owner);
        vault.grantRole(ROLE_TIMELOCK, owner);
        
        // Setup resolution module
        resolutionModule = new DefaultResolutionModule(owner, resolver);
        token.queueDefaultResolutionModule(address(resolutionModule));
        vault.queueDefaultResolutionModule(address(resolutionModule));
        vm.warp(block.timestamp + 14 days + 1);
        token.activateDefaultResolutionModule();
        vault.activateDefaultResolutionModule();
        
        // Distribute tokens
        token.transfer(sender, 100 ether);
        paymentToken.transfer(sender, 100 ether);
        
        vm.prank(sender);
        token.approve(address(token), type(uint256).max);
        
        vm.prank(sender);
        paymentToken.approve(address(vault), type(uint256).max);
    }
    
    // =========================================================================
    // Basic Attachment Tests
    // =========================================================================
    
    function test_Attachment_addSingleAttachment() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        string memory uri = "ipfs://QmTest123";
        bytes32 hash = keccak256("test document");
        
        vm.prank(sender);
        token.addAttachment(workflowId, uri, hash);
        
        // Verify attachment was added
        (string[] memory uris, bytes32[] memory hashes) = token.getAttachments(workflowId);
        assertEq(uris.length, 1, "Should have 1 attachment");
        assertEq(uris[0], uri, "URI should match");
        assertEq(hashes[0], hash, "Hash should match");
    }
    
    function test_Attachment_addMultipleAttachments() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.startPrank(sender);
        token.addAttachment(workflowId, "ipfs://doc1", keccak256("doc1"));
        token.addAttachment(workflowId, "ipfs://doc2", keccak256("doc2"));
        token.addAttachment(workflowId, "ipfs://doc3", keccak256("doc3"));
        vm.stopPrank();
        
        (string[] memory uris, bytes32[] memory hashes) = token.getAttachments(workflowId);
        assertEq(uris.length, 3, "Should have 3 attachments");
        assertEq(hashes.length, 3, "Should have 3 hashes");
    }
    
    function test_Attachment_addEmptyURI() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Empty URI should be allowed (hash is primary identifier)
        vm.prank(sender);
        token.addAttachment(workflowId, "", keccak256("doc"));
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris[0], "", "Empty URI should be stored");
    }
    
    function test_Attachment_addZeroHash() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Zero hash should be allowed (URI is primary identifier)
        vm.prank(sender);
        token.addAttachment(workflowId, "ipfs://doc", bytes32(0));
        
        (, bytes32[] memory hashes) = token.getAttachments(workflowId);
        assertEq(hashes[0], bytes32(0), "Zero hash should be stored");
    }
    
    // =========================================================================
    // Attachment Limits Tests
    // =========================================================================
    
    function test_Attachment_respectMaxLimit() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        uint256 maxAttachments = token.maxAttachments();
        
        // Add up to max
        vm.startPrank(sender);
        for (uint256 i = 0; i < maxAttachments; i++) {
            token.addAttachment(workflowId, string(abi.encodePacked("ipfs://", vm.toString(i))), bytes32(i));
        }
        vm.stopPrank();
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris.length, maxAttachments, "Should have max attachments");
    }
    
    function test_Attachment_cannotExceedMaxLimit() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        uint256 maxAttachments = token.maxAttachments();
        
        // Add max attachments
        vm.startPrank(sender);
        for (uint256 i = 0; i < maxAttachments; i++) {
            token.addAttachment(workflowId, string(abi.encodePacked("ipfs://", vm.toString(i))), bytes32(i));
        }
        
        // Try to add one more
        vm.expectRevert();
        token.addAttachment(workflowId, "ipfs://extra", keccak256("extra"));
        vm.stopPrank();
    }
    
    function test_Attachment_updateMaxLimit() public {
        uint256 newMax = 20;
        
        token.setMaxAttachments(newMax);
        
        assertEq(token.maxAttachments(), newMax, "Should update max");
    }
    
    function test_Attachment_onlyTimelockCanUpdateMaxLimit() public {
        vm.prank(sender);
        vm.expectRevert();
        token.setMaxAttachments(20);
    }
    
    // =========================================================================
    // Access Control Tests
    // =========================================================================
    
    function test_Attachment_onlyParticipantsCanAdd() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Sender can add
        vm.prank(sender);
        token.addAttachment(workflowId, "ipfs://sender", keccak256("sender"));
        
        // Recipient can add
        vm.prank(recipient);
        token.addAttachment(workflowId, "ipfs://recipient", keccak256("recipient"));
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris.length, 2, "Both should be able to add");
    }
    
    function test_Attachment_nonParticipantCannotAdd() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        address attacker = address(0x9999);
        
        vm.prank(attacker);
        vm.expectRevert();
        token.addAttachment(workflowId, "ipfs://attacker", keccak256("attacker"));
    }
    
    function test_Attachment_participantsCanAddAfterDispute() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Raise dispute
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        // Participants (not resolver) can still add attachments after dispute
        vm.prank(sender);
        token.addAttachment(workflowId, "ipfs://evidence", keccak256("evidence"));
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris.length, 1, "Participants should be able to add");
    }
    
    // =========================================================================
    // State-Based Tests
    // =========================================================================
    
    function test_Attachment_canAddToPendingEscrow() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.addAttachment(workflowId, "ipfs://pending", keccak256("pending"));
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris.length, 1);
    }
    
    function test_Attachment_canAddToDisputedEscrow() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.raiseDispute(workflowId);
        
        vm.prank(sender);
        token.addAttachment(workflowId, "ipfs://disputed", keccak256("disputed"));
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris.length, 1);
    }
    
    function test_Attachment_canAddToReleasedEscrow() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        vm.prank(sender);
        token.releaseEscrowTransfer(workflowId);
        
        // Attachments CAN be added to released escrows (for documentation/audit trail)
        vm.prank(sender);
        token.addAttachment(workflowId, "ipfs://released", keccak256("released"));
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris.length, 1, "Should allow adding to released escrow");
    }
    
    // =========================================================================
    // Retrieval Tests
    // =========================================================================
    
    function test_Attachment_getEmptyAttachments() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        (string[] memory uris, bytes32[] memory hashes) = token.getAttachments(workflowId);
        assertEq(uris.length, 0, "Should have no attachments");
        assertEq(hashes.length, 0, "Should have no hashes");
    }
    
    function test_Attachment_getAllAttachments() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        string[3] memory testUris = ["ipfs://1", "ipfs://2", "ipfs://3"];
        bytes32[3] memory testHashes = [keccak256("1"), keccak256("2"), keccak256("3")];
        
        vm.startPrank(sender);
        for (uint256 i = 0; i < 3; i++) {
            token.addAttachment(workflowId, testUris[i], testHashes[i]);
        }
        vm.stopPrank();
        
        (string[] memory uris, bytes32[] memory hashes) = token.getAttachments(workflowId);
        
        for (uint256 i = 0; i < 3; i++) {
            assertEq(uris[i], testUris[i], "URI should match");
            assertEq(hashes[i], testHashes[i], "Hash should match");
        }
    }
    
    // =========================================================================
    // Duplicate Handling Tests
    // =========================================================================
    
    function test_Attachment_allowDuplicateURIs() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        string memory uri = "ipfs://same";
        
        vm.startPrank(sender);
        token.addAttachment(workflowId, uri, keccak256("doc1"));
        token.addAttachment(workflowId, uri, keccak256("doc2"));
        vm.stopPrank();
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris.length, 2, "Should allow duplicate URIs");
    }
    
    function test_Attachment_allowDuplicateHashes() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        bytes32 hash = keccak256("same");
        
        vm.startPrank(sender);
        token.addAttachment(workflowId, "ipfs://1", hash);
        token.addAttachment(workflowId, "ipfs://2", hash);
        vm.stopPrank();
        
        (, bytes32[] memory hashes) = token.getAttachments(workflowId);
        assertEq(hashes.length, 2, "Should allow duplicate hashes");
    }
    
    // =========================================================================
    // Long String Tests
    // =========================================================================
    
    function test_Attachment_handleLongURI() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        // Very long URI
        string memory longUri = "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG/very/long/path/to/document/with/many/folders/and/a/very/long/filename/that/tests/string/handling.pdf";
        
        vm.prank(sender);
        token.addAttachment(workflowId, longUri, keccak256("long"));
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris[0], longUri, "Should handle long URI");
    }
    
    // =========================================================================
    // EscrowVault Attachment Tests
    // =========================================================================
    
    function test_Attachment_vaultSingleAttachment() public {
        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(paymentToken), recipient, AMOUNT);
        
        vm.prank(sender);
        vault.addAttachment(workflowId, "ipfs://vault", keccak256("vault"));
        
        (string[] memory uris,) = vault.getAttachments(workflowId);
        assertEq(uris.length, 1);
    }
    
    function test_Attachment_vaultMultipleAttachments() public {
        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(paymentToken), recipient, AMOUNT);
        
        vm.startPrank(sender);
        vault.addAttachment(workflowId, "ipfs://1", keccak256("1"));
        vault.addAttachment(workflowId, "ipfs://2", keccak256("2"));
        vm.stopPrank();
        
        (string[] memory uris,) = vault.getAttachments(workflowId);
        assertEq(uris.length, 2);
    }
    
    function test_Attachment_vaultMaxLimit() public {
        vm.prank(sender);
        uint256 workflowId = vault.createEscrow(address(paymentToken), recipient, AMOUNT);
        
        uint256 maxAttachments = vault.maxAttachments();
        
        vm.startPrank(sender);
        for (uint256 i = 0; i < maxAttachments; i++) {
            vault.addAttachment(workflowId, string(abi.encodePacked("ipfs://", vm.toString(i))), bytes32(i));
        }
        
        vm.expectRevert();
        vault.addAttachment(workflowId, "ipfs://extra", keccak256("extra"));
        vm.stopPrank();
    }
    
    // =========================================================================
    // Edge Cases
    // =========================================================================
    
    function test_Attachment_nonExistentWorkflowId() public {
        uint256 nonExistentId = 999;
        
        vm.prank(sender);
        vm.expectRevert();
        token.addAttachment(nonExistentId, "ipfs://test", keccak256("test"));
    }
    
    function test_Attachment_getFromNonExistentWorkflow() public {
        uint256 nonExistentId = 999;
        
        // Getting attachments from non-existent workflow reverts with InvalidWorkflowId
        vm.expectRevert();
        token.getAttachments(nonExistentId);
    }
    
    function test_Attachment_specialCharactersInURI() public {
        vm.prank(sender);
        uint256 workflowId = token.createEscrow(recipient, AMOUNT);
        
        string memory specialUri = "ipfs://test?query=value&foo=bar#anchor";
        
        vm.prank(sender);
        token.addAttachment(workflowId, specialUri, keccak256("special"));
        
        (string[] memory uris,) = token.getAttachments(workflowId);
        assertEq(uris[0], specialUri, "Should handle special characters");
    }
    
    function test_Attachment_unicodeInURI() public {
        vm.prank(sender);
    }
}
