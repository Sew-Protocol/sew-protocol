// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import '../../../contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol';
import '../../../contracts/modules/decentralized-resolution-module/BondTokenRegistry.sol';
import '../../../contracts/modules/decentralized-resolution-module/DecentralizedResolverStructs.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/types/EscrowTypes.sol';

/**
 * @title BondTokenWhitelistTest
 * @notice Tests for appeal bond token whitelist functionality via BondTokenRegistry
 * @dev Verifies that only whitelisted tokens can be used for appeal bonds,
 *      with governance control over the whitelist and default token.
 *      BondTokenRegistry is the standalone contract that replaced the inline whitelist
 *      in DecentralizedResolutionModule.
 */
contract BondTokenWhitelistTest is Test {
    BondTokenRegistry public registry;
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

        // Deploy registry with ETH (address(0)) as default token
        registry = new BondTokenRegistry(owner, address(0));
        registry.grantRole(ROLE_TIMELOCK, timelock);

        // Deploy resolution module and wire up the registry
        resolutionModule = new DecentralizedResolutionModule(owner);
        DRMAdminFacet drmAdminFacet_ = new DRMAdminFacet();
        resolutionModule.setAdminFacet(address(drmAdminFacet_));
        resolutionModule.grantRole(ROLE_TIMELOCK, timelock);
        vm.prank(timelock);
        resolutionModule.setBondTokenRegistry(address(registry));

        // Deploy mock tokens
        usdcToken = new ERC20Mock('USD Coin', 'USDC', owner, 1000000e6);
        usdtToken = new ERC20Mock('Tether', 'USDT', owner, 1000000e6);
        daiToken = new ERC20Mock('Dai', 'DAI', owner, 1000000e18);
    }

    /**
     * @notice Test that ETH (address(0)) is in whitelist by default
     */
    function test_ETH_InWhitelistByDefault() public {
        assertTrue(registry.isAccepted(address(0)), 'ETH should be accepted by default');
        assertEq(registry.defaultBondToken(), address(0), 'ETH should be default bond token');
    }

    /**
     * @notice Test adding a token to the whitelist via governance
     */
    function test_AddTokenToWhitelist() public {
        // Token not in whitelist initially
        assertFalse(registry.isAccepted(address(usdcToken)), 'USDC should not be in whitelist initially');

        // Queue addition
        vm.prank(timelock);
        registry.queueAddAcceptedBondToken(address(usdcToken));

        // Verify pending change
        (address token, bool isAdd, uint64 eta, bool exists) = registry.getPendingBondTokenChange();
        assertEq(token, address(usdcToken), 'Pending token should be USDC');
        assertTrue(isAdd, 'Pending change should be add');
        assertTrue(exists, 'Pending change should exist');
        assertTrue(eta > block.timestamp, 'ETA should be in future');

        // Wait for timelock
        vm.warp(eta + 1);

        // Activate addition
        vm.prank(timelock);
        registry.activateBondTokenWhitelistChange();

        // Verify token is now in whitelist
        assertTrue(registry.isAccepted(address(usdcToken)), 'USDC should be in whitelist after activation');
    }

    /**
     * @notice Test removing a token from the whitelist (when it's not default)
     */
    function test_RemoveTokenFromWhitelist() public {
        // Add token to whitelist first
        vm.prank(timelock);
        registry.queueAddAcceptedBondToken(address(usdcToken));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        registry.activateBondTokenWhitelistChange();

        assertTrue(registry.isAccepted(address(usdcToken)), 'USDC should be in whitelist');

        // Queue removal
        vm.prank(timelock);
        registry.queueRemoveAcceptedBondToken(address(usdcToken));

        // Verify pending change
        (address token, bool isAdd, uint64 eta, bool exists) = registry.getPendingBondTokenChange();
        assertEq(token, address(usdcToken), 'Pending token should be USDC');
        assertFalse(isAdd, 'Pending change should be remove');

        // Wait for timelock
        vm.warp(eta + 1);

        // Activate removal
        vm.prank(timelock);
        registry.activateBondTokenWhitelistChange();

        // Verify token is removed from whitelist
        assertFalse(registry.isAccepted(address(usdcToken)), 'USDC should not be in whitelist after removal');
    }

    /**
     * @notice Test that cannot add token that's already in whitelist
     */
    function test_CannotAddDuplicateToken() public {
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(BondTokenRegistry.TokenAlreadyInWhitelist.selector, address(0))
        );
        registry.queueAddAcceptedBondToken(address(0));
    }

    /**
     * @notice Test that cannot remove default token
     */
    function test_CannotRemoveDefaultToken() public {
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(BondTokenRegistry.CannotRemoveDefaultToken.selector, address(0))
        );
        registry.queueRemoveAcceptedBondToken(address(0));
    }

    /**
     * @notice Test setting default bond token
     */
    function test_SetDefaultBondToken() public {
        // Add USDC to whitelist first
        vm.prank(timelock);
        registry.queueAddAcceptedBondToken(address(usdcToken));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(timelock);
        registry.activateBondTokenWhitelistChange();

        // Verify ETH is still default
        assertEq(registry.defaultBondToken(), address(0), 'ETH should be default initially');

        // Queue USDC as new default
        vm.prank(timelock);
        registry.queueSetDefaultBondToken(address(usdcToken));

        // Verify pending change
        (address token, uint64 eta, bool exists) = registry.getPendingDefaultBondToken();
        assertEq(token, address(usdcToken), 'Pending default should be USDC');
        assertTrue(exists, 'Pending change should exist');

        // Wait for timelock
        vm.warp(eta + 1);

        // Activate change
        vm.prank(timelock);
        registry.activateDefaultBondToken();

        // Verify USDC is now default
        assertEq(registry.defaultBondToken(), address(usdcToken), 'USDC should be default after activation');
    }

    /**
     * @notice Test that cannot set non-whitelisted token as default
     */
    function test_CannotSetNonWhitelistedTokenAsDefault() public {
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(BondTokenRegistry.TokenNotInWhitelist.selector, address(usdcToken))
        );
        registry.queueSetDefaultBondToken(address(usdcToken));
    }

    /**
     * @notice Test getRequiredAppealBond returns whitelisted token (integration)
     */
    function test_GetRequiredAppealBond_ReturnsWhitelistedToken() public {
        bytes memory escrowData = abi.encode(address(0), owner, owner, uint256(1));
        (uint256 amount, address token) = resolutionModule.getRequiredAppealBond(0, address(0), 0, escrowData);

        assertGt(amount, 0, 'Bond amount should be > 0');
        assertEq(token, address(0), 'Token should be ETH');
    }

    /**
     * @notice Test getRequiredAppealBond honours registry default (integration)
     */
    function test_GetRequiredAppealBond_UsesDefaultToken() public {
        vm.prank(timelock);
        registry.queueAddAcceptedBondToken(address(usdcToken));
        (, , uint64 eta1, ) = registry.getPendingBondTokenChange();
        vm.warp(uint256(eta1) + 1);
        vm.prank(timelock);
        registry.activateBondTokenWhitelistChange();

        vm.prank(timelock);
        registry.queueSetDefaultBondToken(address(usdcToken));
        (, uint64 eta2, ) = registry.getPendingDefaultBondToken();
        vm.warp(uint256(eta2) + 1);
        vm.prank(timelock);
        registry.activateDefaultBondToken();

        bytes memory escrowData = abi.encode(address(usdcToken), owner, owner, uint256(1));
        (uint256 amount, address token) = resolutionModule.getRequiredAppealBond(0, address(0), 0, escrowData);

        assertGt(amount, 0, 'Bond amount should be > 0');
        assertEq(token, address(usdcToken), 'Token should match escrow token');
    }

    /**
     * @notice Test getAcceptedBondTokens returns list of whitelisted tokens
     */
    function test_GetAcceptedBondTokensList() public {
        vm.prank(timelock);
        registry.queueAddAcceptedBondToken(address(usdcToken));
        (, , uint64 eta1, ) = registry.getPendingBondTokenChange();
        vm.warp(uint256(eta1) + 1);
        vm.prank(timelock);
        registry.activateBondTokenWhitelistChange();

        vm.prank(timelock);
        registry.queueAddAcceptedBondToken(address(usdtToken));
        (, , uint64 eta2, ) = registry.getPendingBondTokenChange();
        vm.warp(uint256(eta2) + 1);
        vm.prank(timelock);
        registry.activateBondTokenWhitelistChange();

        address[] memory tokens = registry.getAcceptedBondTokens();

        assertEq(tokens.length, 3, 'Should have 3 tokens (ETH, USDC, USDT)');
        assertEq(tokens[0], address(0), 'First token should be ETH');
        assertEq(tokens[1], address(usdcToken), 'Second token should be USDC');
        assertEq(tokens[2], address(usdtToken), 'Third token should be USDT');
    }

    /**
     * @notice Test multiple tokens in whitelist
     */
    function test_MultipleTokensInWhitelist() public {
        address[] memory tokensToAdd = new address[](3);
        tokensToAdd[0] = address(usdcToken);
        tokensToAdd[1] = address(usdtToken);
        tokensToAdd[2] = address(daiToken);

        for (uint256 i = 0; i < tokensToAdd.length; i++) {
            vm.prank(timelock);
            registry.queueAddAcceptedBondToken(tokensToAdd[i]);
            (, , uint64 eta, ) = registry.getPendingBondTokenChange();
            vm.warp(uint256(eta) + 1);
            vm.prank(timelock);
            registry.activateBondTokenWhitelistChange();
        }

        for (uint256 i = 0; i < tokensToAdd.length; i++) {
            assertTrue(registry.isAccepted(tokensToAdd[i]), 'Token should be in whitelist');
        }

        address[] memory accepted = registry.getAcceptedBondTokens();
        assertEq(accepted.length, 4, 'Should have 4 tokens (ETH + 3 stablecoins)');
    }

    /**
     * @notice Test default bond token fallback logic
     */
    function test_DefaultBondTokenFallback() public {
        assertEq(registry.defaultBondToken(), address(0));

        vm.prank(timelock);
        registry.queueAddAcceptedBondToken(address(usdcToken));
        (, , uint64 eta1, ) = registry.getPendingBondTokenChange();
        vm.warp(uint256(eta1) + 1);
        vm.prank(timelock);
        registry.activateBondTokenWhitelistChange();

        assertTrue(registry.isAccepted(address(usdcToken)), 'USDC should be in whitelist');

        vm.prank(timelock);
        registry.queueSetDefaultBondToken(address(usdcToken));
        (, uint64 eta2, ) = registry.getPendingDefaultBondToken();
        vm.warp(uint256(eta2) + 1);
        vm.prank(timelock);
        registry.activateDefaultBondToken();

        bytes memory escrowData = abi.encode(address(usdcToken), owner, owner, uint256(1));
        (, address token) = resolutionModule.getRequiredAppealBond(0, address(0), 0, escrowData);
        assertEq(token, address(usdcToken), 'Token should match escrow token');
    }

    /**
     * @notice Test queuing escalation cost config with whitelisted token (DRM integration)
     */
    function test_QueueEscalationCostConfig_WhitelistedToken() public {
        vm.prank(timelock);
        registry.queueAddAcceptedBondToken(address(usdcToken));
        (, , uint64 eta, ) = registry.getPendingBondTokenChange();
        vm.warp(uint256(eta) + 1);
        vm.prank(timelock);
        registry.activateBondTokenWhitelistChange();

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
    }
}
