// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';

/**
 * @title BondTokenWhitelistTest
 * @notice Tests for appeal bond token whitelist functionality
 * @dev Verifies that only whitelisted tokens can be used for appeal bonds,
 *      with governance control over the whitelist and default token
 */
contract BondTokenWhitelistTest is Test {
    DecentralizedResolutionModule public resolutionModule;
    ERC20Mock public usdcToken;
    ERC20Mock public usdtToken;
    ERC20Mock public daiToken;

    address public owner;
    address public timelock;

    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    function setUp() public {
        owner = address(this);
        timelock = makeAddr('timelock');

        // Deploy resolution module
        resolutionModule = new DecentralizedResolutionModule(owner);

        // Deploy mock tokens
        usdcToken = new ERC20Mock('USD Coin', 'USDC', owner, 1000000e6);
        usdtToken = new ERC20Mock('Tether', 'USDT', owner, 1000000e6);
        daiToken = new ERC20Mock('Dai', 'DAI', owner, 1000000e18);

        // Grant ROLE_TIMELOCK to timelock
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);
    }

    /**
     * @notice Test that ETH (address(0)) is in whitelist by default
     */
    function test_ETH_InWhitelistByDefault() public {
        assertTrue(resolutionModule.acceptedBondTokens(address(0)), 'ETH should be accepted by default');
        assertEq(resolutionModule.defaultBondToken(), address(0), 'ETH should be default bond token');
    }

    /**
     * @notice Test adding a token to the whitelist via governance
     */
    function test_AddTokenToWhitelist() public {
        // Token not in whitelist initially
        assertFalse(resolutionModule.acceptedBondTokens(address(usdcToken)), 'USDC should not be in whitelist initially');

        // Queue addition
        vm.prank(timelock);
        resolutionModule.queueAddAcceptedBondToken(address(usdcToken));

        // Verify pending change
        (address token, bool isAdd, uint64 eta, bool exists) = resolutionModule.getPendingBondTokenChange();
        assertEq(token, address(usdcToken), 'Pending token should be USDC');
        assertTrue(isAdd, 'Pending change should be add');
        assertTrue(exists, 'Pending change should exist');
        assertTrue(eta > block.timestamp, 'ETA should be in future');

        // Wait for timelock
        vm.warp(eta + 1);

        // Activate addition
        vm.prank(timelock);
        resolutionModule.activateBondTokenWhitelistChange();

        // Verify token is now in whitelist
        assertTrue(resolutionModule.acceptedBondTokens(address(usdcToken)), 'USDC should be in whitelist after activation');
    }

    /**
     * @notice Test removing a token from the whitelist (when it's not default)
     */
    function test_RemoveTokenFromWhitelist() public {
        // Add token to whitelist first
        vm.prank(timelock);
        resolutionModule.queueAddAcceptedBondToken(address(usdcToken));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        resolutionModule.activateBondTokenWhitelistChange();

        assertTrue(resolutionModule.acceptedBondTokens(address(usdcToken)), 'USDC should be in whitelist');

        // Queue removal
        vm.prank(timelock);
        resolutionModule.queueRemoveAcceptedBondToken(address(usdcToken));

        // Verify pending change
        (address token, bool isAdd, uint64 eta, bool exists) = resolutionModule.getPendingBondTokenChange();
        assertEq(token, address(usdcToken), 'Pending token should be USDC');
        assertFalse(isAdd, 'Pending change should be remove');

        // Wait for timelock
        vm.warp(eta + 1);

        // Activate removal
        vm.prank(timelock);
        resolutionModule.activateBondTokenWhitelistChange();

        // Verify token is removed from whitelist
        assertFalse(resolutionModule.acceptedBondTokens(address(usdcToken)), 'USDC should not be in whitelist after removal');
    }

    /**
     * @notice Test that cannot add token that's already in whitelist
     */
    function test_CannotAddDuplicateToken() public {
        // Try to add ETH (already in whitelist)
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                DecentralizedResolutionModule.TokenAlreadyInWhitelist.selector,
                address(0)
            )
        );
        resolutionModule.queueAddAcceptedBondToken(address(0));
    }

    /**
     * @notice Test that cannot remove default token
     */
    function test_CannotRemoveDefaultToken() public {
        // Try to remove ETH (which is default)
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                DecentralizedResolutionModule.CannotRemoveDefaultToken.selector,
                address(0)
            )
        );
        resolutionModule.queueRemoveAcceptedBondToken(address(0));
    }

    /**
     * @notice Test setting default bond token
     */
    function test_SetDefaultBondToken() public {
        // Add USDC to whitelist first
        vm.prank(timelock);
        resolutionModule.queueAddAcceptedBondToken(address(usdcToken));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        resolutionModule.activateBondTokenWhitelistChange();

        // Verify ETH is still default
        assertEq(resolutionModule.defaultBondToken(), address(0), 'ETH should be default initially');

        // Queue USDC as new default
        vm.prank(timelock);
        resolutionModule.queueSetDefaultBondToken(address(usdcToken));

        // Verify pending change
        (address token, uint64 eta, bool exists) = resolutionModule.getPendingDefaultBondToken();
        assertEq(token, address(usdcToken), 'Pending default should be USDC');
        assertTrue(exists, 'Pending change should exist');

        // Wait for timelock
        vm.warp(eta + 1);

        // Activate change
        vm.prank(timelock);
        resolutionModule.activateDefaultBondToken();

        // Verify USDC is now default
        assertEq(resolutionModule.defaultBondToken(), address(usdcToken), 'USDC should be default after activation');
    }

    /**
     * @notice Test that cannot set non-whitelisted token as default
     */
    function test_CannotSetNonWhitelistedTokenAsDefault() public {
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                DecentralizedResolutionModule.TokenNotInWhitelist.selector,
                address(usdcToken)
            )
        );
        resolutionModule.queueSetDefaultBondToken(address(usdcToken));
    }

    /**
     * @notice Test getRequiredAppealBond returns whitelisted token
     */
    function test_GetRequiredAppealBond_ReturnsWhitelistedToken() public {
        // SECURITY: bond token is enforced to match escrow token.
        // Provide escrowData encoded as (token, from, to, amount).
        bytes memory escrowData = abi.encode(address(0), owner, owner, uint256(1));
        (uint256 amount, address token) = resolutionModule.getRequiredAppealBond(0, address(0), 0, escrowData);

        assertGt(amount, 0, 'Bond amount should be > 0');
        assertEq(token, address(0), 'Token should be ETH');
    }

    /**
     * @notice Test getRequiredAppealBond uses default token when set
     */
    function test_GetRequiredAppealBond_UsesDefaultToken() public {
        // Block 1: Add USDC to whitelist
        vm.prank(timelock);
        resolutionModule.queueAddAcceptedBondToken(address(usdcToken));
        (address qToken1, bool isAdd1, uint64 eta1, bool exists1) = resolutionModule.getPendingBondTokenChange();
        vm.warp(uint256(eta1) + 1);
        vm.prank(timelock);
        resolutionModule.activateBondTokenWhitelistChange();

        // Block 2: Set USDC as default
        vm.prank(timelock);
        resolutionModule.queueSetDefaultBondToken(address(usdcToken));
        (address defToken, uint64 eta2, bool exists2) = resolutionModule.getPendingDefaultBondToken();
        vm.warp(uint256(eta2) + 1);
        vm.prank(timelock);
        resolutionModule.activateDefaultBondToken();

        // Get required bond: token is enforced to match escrow token (not default token)
        bytes memory escrowData = abi.encode(address(usdcToken), owner, owner, uint256(1));
        (uint256 amount, address token) = resolutionModule.getRequiredAppealBond(0, address(0), 0, escrowData);

        assertGt(amount, 0, 'Bond amount should be > 0');
        assertEq(token, address(usdcToken), 'Token should match escrow token');
    }

    /**
     * @notice Test GetAcceptedBondTokens returns list of whitelisted tokens
     */
    function test_GetAcceptedBondTokensList() public {
        // Block 1: Add first token
        vm.prank(timelock);
        resolutionModule.queueAddAcceptedBondToken(address(usdcToken));
        (address qToken1, bool isAdd1, uint64 eta1, bool exists1) = resolutionModule.getPendingBondTokenChange();
        vm.warp(uint256(eta1) + 1);
        vm.prank(timelock);
        resolutionModule.activateBondTokenWhitelistChange();

        // Block 2: Add second token
        vm.prank(timelock);
        resolutionModule.queueAddAcceptedBondToken(address(usdtToken));
        (address qToken2, bool isAdd2, uint64 eta2, bool exists2) = resolutionModule.getPendingBondTokenChange();
        vm.warp(uint256(eta2) + 1);
        vm.prank(timelock);
        resolutionModule.activateBondTokenWhitelistChange();

        // Get list
        address[] memory tokens = resolutionModule.getAcceptedBondTokens();

        assertEq(tokens.length, 3, 'Should have 3 tokens (ETH, USDC, USDT)');
        assertEq(tokens[0], address(0), 'First token should be ETH');
        assertEq(tokens[1], address(usdcToken), 'Second token should be USDC');
        assertEq(tokens[2], address(usdtToken), 'Third token should be USDT');
    }

    /**
     * @notice Test queuing escalation cost config with whitelisted token
     */
    function test_QueueEscalationCostConfig_WhitelistedToken() public {
        // Add USDC to whitelist
        vm.prank(timelock);
        resolutionModule.queueAddAcceptedBondToken(address(usdcToken));
        (address qToken, bool isAdd, uint64 eta, bool exists) = resolutionModule.getPendingBondTokenChange();
        vm.warp(uint256(eta) + 1);
        vm.prank(timelock);
        resolutionModule.activateBondTokenWhitelistChange();

        // Queue config with USDC token - should now succeed since USDC is in whitelist
        DecentralizedResolverStructs.EscalationCostConfig memory config = DecentralizedResolverStructs
            .EscalationCostConfig({
                enabled: true,
                curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
                baseCost: 0.01 ether,
                stepSize: 0.01 ether,
                multiplier: 0,
                bondToken: address(usdcToken)
            });

        vm.prank(timelock);
        resolutionModule.queueEscalationCostConfig(config);

        // Should succeed without error
    }

    /**
     * @notice Test queuing escalation cost config with non-whitelisted token (allowed for backward compatibility)
     */
    function test_QueueEscalationCostConfig_NonWhitelistedToken_AllowedForBackwardCompat() public {
        DecentralizedResolverStructs.EscalationCostConfig memory config = DecentralizedResolverStructs
            .EscalationCostConfig({
                enabled: true,
                curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
                baseCost: 0.01 ether,
                stepSize: 0.01 ether,
                multiplier: 0,
                bondToken: address(usdcToken) // Not in whitelist, but allowed for backward compatibility
            });

        vm.prank(timelock);
        // Should not revert - queuing is allowed, even with non-whitelisted token
        resolutionModule.queueEscalationCostConfig(config);
    }

    /**
     * @notice Test multiple tokens in whitelist
     */
    function test_MultipleTokensInWhitelist() public {
        // Add multiple tokens sequentially, using retrieved ETA for each
        address[] memory tokensToAdd = new address[](3);
        tokensToAdd[0] = address(usdcToken);
        tokensToAdd[1] = address(usdtToken);
        tokensToAdd[2] = address(daiToken);

        for (uint256 i = 0; i < tokensToAdd.length; i++) {
            vm.prank(timelock);
            resolutionModule.queueAddAcceptedBondToken(tokensToAdd[i]);
            (address qToken, bool isAdd, uint64 eta, bool exists) = resolutionModule.getPendingBondTokenChange();
            vm.warp(uint256(eta) + 1);
            vm.prank(timelock);
            resolutionModule.activateBondTokenWhitelistChange();
        }

        // Verify all tokens are in whitelist
        for (uint256 i = 0; i < tokensToAdd.length; i++) {
            assertTrue(
                resolutionModule.acceptedBondTokens(tokensToAdd[i]),
                'Token should be in whitelist'
            );
        }

        // Verify list contains all tokens
        address[] memory accepted = resolutionModule.getAcceptedBondTokens();
        assertEq(accepted.length, 4, 'Should have 4 tokens (ETH + 3 stablecoins)');
    }

    /**
     * @notice Test default bond token fallback logic
     */
    function test_DefaultBondTokenFallback() public {
        // Initially default is ETH
        assertEq(resolutionModule.defaultBondToken(), address(0));

        // Add USDC and set as default - but do it in separate test-like blocks with sufficient time
        // Block 1: Queue and activate USDC addition
        vm.prank(timelock);
        resolutionModule.queueAddAcceptedBondToken(address(usdcToken));
        (address qToken, bool isAdd, uint64 eta1, bool exists1) = resolutionModule.getPendingBondTokenChange();
        vm.warp(uint256(eta1) + 1);
        vm.prank(timelock);
        resolutionModule.activateBondTokenWhitelistChange();

        // Verify USDC is now in whitelist
        assertTrue(resolutionModule.acceptedBondTokens(address(usdcToken)), 'USDC should be in whitelist');

        // Block 2: Queue and activate USDC as default (separate block with fresh time calculation)
        vm.prank(timelock);
        resolutionModule.queueSetDefaultBondToken(address(usdcToken));
        (address defToken, uint64 eta2, bool exists2) = resolutionModule.getPendingDefaultBondToken();
        vm.warp(uint256(eta2) + 1);
        vm.prank(timelock);
        resolutionModule.activateDefaultBondToken();

        // SECURITY: getRequiredAppealBond enforces bond token matches escrow token.
        bytes memory escrowData = abi.encode(address(usdcToken), owner, owner, uint256(1));
        (, address token) = resolutionModule.getRequiredAppealBond(0, address(0), 0, escrowData);
        assertEq(token, address(usdcToken), 'Token should match escrow token');
    }
}
