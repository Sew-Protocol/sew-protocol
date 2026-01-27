// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import { ERC20Mock } from "../../../contracts/mocks/ERC20Mock.sol";
import { AaveYieldGenerationModule } from "../../../contracts/modules/AaveYieldGenerationModule.sol";

contract MockAToken {
    address public immutable underlyingAsset;
    mapping(address => uint256) public balanceOf;

    constructor(address underlying) {
        underlyingAsset = underlying;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "aToken/insufficient");
        balanceOf[from] -= amount;
    }
}

contract MockPool {
    mapping(address => address) public assetToAToken;
    mapping(address => uint256) public yieldBps; // asset => yield in bps paid on withdraw

    function setAToken(address asset, address aToken) external {
        assetToAToken[asset] = aToken;
    }

    function setYieldBps(address asset, uint256 bps) external {
        require(bps <= 10_000, "bps");
        yieldBps[asset] = bps;
    }

    // Mimic a simple "supply": pull underlying from msg.sender, mint aTokens to onBehalfOf 1:1.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        address aToken = assetToAToken[asset];
        require(aToken != address(0), "pool/no-aToken");

        // Pull underlying from msg.sender (matches Aave's msg.sender semantics).
        ERC20Mock(asset).transferFrom(msg.sender, address(this), amount);
        MockAToken(aToken).mint(onBehalfOf, amount);
    }

    // Mimic a simple "withdraw": burn aTokens from msg.sender, return principal + yield to `to`.
    // NOTE: The module passes "amount" as the recorded aToken balance; this mock treats it as aToken amount.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        address aToken = assetToAToken[asset];
        require(aToken != address(0), "pool/no-aToken");

        // Burn aTokens from module (msg.sender)
        MockAToken(aToken).burn(msg.sender, amount);

        uint256 y = (amount * yieldBps[asset]) / 10_000;
        uint256 payout = amount + y;

        // Ensure pool can pay: mint yield if needed (test-only; simulates interest accrual).
        if (ERC20Mock(asset).balanceOf(address(this)) < payout) {
            ERC20Mock(asset).mint(address(this), payout - ERC20Mock(asset).balanceOf(address(this)));
        }

        ERC20Mock(asset).transfer(to, payout);
        return payout;
    }
}

/// @dev Variant pool that pulls underlying from `onBehalfOf` instead of msg.sender.
/// This is NOT how Aave Pool works, but it allows exercising module accounting end-to-end
/// while reflecting the current module call pattern (module calls pool, escrow holds funds).
contract MockPoolEscrowPull {
    mapping(address => address) public assetToAToken;
    mapping(address => uint256) public yieldBps; // asset => yield in bps paid on withdraw

    function setAToken(address asset, address aToken) external {
        assetToAToken[asset] = aToken;
    }

    function setYieldBps(address asset, uint256 bps) external {
        require(bps <= 10_000, "bps");
        yieldBps[asset] = bps;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        address aToken = assetToAToken[asset];
        require(aToken != address(0), "pool/no-aToken");

        // Pull underlying from onBehalfOf (escrow contract) to this pool.
        ERC20Mock(asset).transferFrom(onBehalfOf, address(this), amount);
        MockAToken(aToken).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        address aToken = assetToAToken[asset];
        require(aToken != address(0), "pool/no-aToken");

        // Burn aTokens from module (msg.sender)
        MockAToken(aToken).burn(msg.sender, amount);

        uint256 y = (amount * yieldBps[asset]) / 10_000;
        uint256 payout = amount + y;

        if (ERC20Mock(asset).balanceOf(address(this)) < payout) {
            ERC20Mock(asset).mint(address(this), payout - ERC20Mock(asset).balanceOf(address(this)));
        }

        ERC20Mock(asset).transfer(to, payout);
        return payout;
    }
}

contract MockPoolAddressesProvider {
    address internal pool;

    constructor(address _pool) {
        pool = _pool;
    }

    function getPool() external view returns (address) {
        return pool;
    }
}

contract Phase2AaveYieldGenerationModuleTest is Test {
    bytes32 internal constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    bytes32 internal constant ROLE_GUARDIAN = keccak256("ROLE_GUARDIAN");

    function test_phase2_aave_module_deposit_withdraw_yield_and_caps_simulated_pool() public {
        // Deploy mocks
        address timelock = address(this);
        address guardian = makeAddr("guardian");
        address escrowContract = makeAddr("escrowContract"); // caller identity in the module mappings

        ERC20Mock token = new ERC20Mock("Aave Sim Token", "AST", escrowContract, 1_000_000e18);
        MockAToken aToken = new MockAToken(address(token));
        MockPoolEscrowPull pool = new MockPoolEscrowPull();
        pool.setAToken(address(token), address(aToken));
        pool.setYieldBps(address(token), 500); // 5% yield

        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(pool));

        // Deploy module and grant roles to this test contract
        AaveYieldGenerationModule module = new AaveYieldGenerationModule(timelock);
        module.grantRole(ROLE_TIMELOCK, timelock);
        module.grantRole(ROLE_GUARDIAN, guardian);

        // Configure provider via slow lane queue/activate
        module.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        module.activateAavePoolProvider();

        // Register token/aToken and set caps
        module.registerTokenForAave(address(token), address(aToken));
        module.setTokenCap(address(token), 10_000e18);
        module.setGlobalCap(address(token), 10_000e18);

        // Deposit for yield as escrowContract
        uint256 workflowId = 1;
        uint256 depositAmount = 100e18;

        vm.startPrank(escrowContract);
        token.approve(address(pool), depositAmount);
        token.approve(address(module), depositAmount);
        (bool ok, uint256 yBal) = module.depositForYield(workflowId, address(token), depositAmount);
        vm.stopPrank();

        assertTrue(ok, "deposit should succeed");
        assertEq(yBal, MockAToken(address(aToken)).balanceOf(address(module)), "aToken balance mismatch");
        assertTrue(module.escrowInAave(escrowContract, workflowId), "escrowInAave not set");
        assertEq(module.escrowOriginalDeposit(escrowContract, workflowId), depositAmount, "original deposit mismatch");
        assertEq(module.getTotalDepositedToAave(address(token)), depositAmount, "totalDepositedToAave mismatch");
        assertEq(module.currentExposure(address(token)), depositAmount, "exposure mismatch");

        // Withdraw with yield as escrowContract (same msg.sender as deposit path expects)
        uint256 balBefore = token.balanceOf(escrowContract);
        vm.prank(escrowContract);
        (bool wOk, uint256 actual, uint256 y) = module.withdrawWithYield(workflowId, address(token), depositAmount);
        uint256 balAfter = token.balanceOf(escrowContract);

        assertTrue(wOk, "withdraw should succeed");
        assertEq(actual, depositAmount + (depositAmount * 500) / 10_000, "actual amount mismatch");
        assertEq(y, (depositAmount * 500) / 10_000, "yield amount mismatch");
        assertEq(balAfter - balBefore, actual, "escrow payout mismatch");

        // State cleared + exposure reduced
        assertTrue(!module.escrowInAave(escrowContract, workflowId), "escrowInAave not cleared");
        assertEq(module.escrowATokenBalance(escrowContract, workflowId), 0, "aToken balance not cleared");
        assertEq(module.escrowOriginalDeposit(escrowContract, workflowId), 0, "original deposit not cleared");
        assertEq(module.currentExposure(address(token)), 0, "exposure not reduced");
    }

    function test_phase2_aave_deposit_strict_pool_semantics_reverts_without_module_funds() public {
        // This test captures a key integration constraint:
        // Aave Pool.supply pulls underlying from msg.sender (the module), but the module
        // does not hold funds by default. In production, the escrow integration must ensure
        // the pool can pull funds from the correct holder (or adjust the call pattern).
        address timelock = address(this);
        address escrowContract = makeAddr("escrowContract");

        ERC20Mock token = new ERC20Mock("Aave Sim Token", "AST", escrowContract, 1_000_000e18);
        MockAToken aToken = new MockAToken(address(token));
        MockPool pool = new MockPool(); // strict: pulls from msg.sender
        pool.setAToken(address(token), address(aToken));
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(pool));

        AaveYieldGenerationModule module = new AaveYieldGenerationModule(timelock);
        module.grantRole(ROLE_TIMELOCK, timelock);
        module.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        module.activateAavePoolProvider();
        module.registerTokenForAave(address(token), address(aToken));

        // Escrow approves pool, but module is msg.sender to supply; module has no funds/allowance → revert.
        vm.startPrank(escrowContract);
        token.approve(address(pool), 100e18);
        vm.expectRevert();
        module.depositForYield(1, address(token), 100e18);
        vm.stopPrank();
    }

    function test_phase2_caps_enforced_on_deposit() public {
        address timelock = address(this);
        address escrowContract = makeAddr("escrowContract");

        ERC20Mock token = new ERC20Mock("Aave Sim Token", "AST", escrowContract, 1_000_000e18);
        MockAToken aToken = new MockAToken(address(token));
        MockPoolEscrowPull pool = new MockPoolEscrowPull();
        pool.setAToken(address(token), address(aToken));
        MockPoolAddressesProvider provider = new MockPoolAddressesProvider(address(pool));

        AaveYieldGenerationModule module = new AaveYieldGenerationModule(timelock);
        module.grantRole(ROLE_TIMELOCK, timelock);

        module.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        module.activateAavePoolProvider();
        module.registerTokenForAave(address(token), address(aToken));

        // Cap below deposit
        module.setTokenCap(address(token), 10e18);
        module.setGlobalCap(address(token), 10e18);

        uint256 workflowId = 1;
        uint256 depositAmount = 11e18;

        vm.startPrank(escrowContract);
        token.approve(address(pool), depositAmount);
        vm.expectRevert(); // CapExceeded
        module.depositForYield(workflowId, address(token), depositAmount);
        vm.stopPrank();
    }

    function test_phase2_disabled_or_unregistered_token_is_non_blocking() public {
        address timelock = address(this);
        address escrowContract = makeAddr("escrowContract");

        ERC20Mock token = new ERC20Mock("Aave Sim Token", "AST", escrowContract, 1_000_000e18);
        AaveYieldGenerationModule module = new AaveYieldGenerationModule(timelock);
        module.grantRole(ROLE_TIMELOCK, timelock);

        // Aave not enabled and no token registered → deposit returns (true, 0)
        vm.prank(escrowContract);
        (bool ok, uint256 yBal) = module.depositForYield(1, address(token), 100e18);
        assertTrue(ok, "deposit should be non-blocking");
        assertEq(yBal, 0, "expected zero aToken balance");
    }
}

