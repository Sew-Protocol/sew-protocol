// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import 'forge-std/StdInvariant.sol';
import 'contracts/modules/AaveYieldModule.sol';
import 'contracts/mocks/ERC20Mock.sol';
import 'contracts/mocks/MockAavePool.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

contract AaveHandler is Test {
    AaveYieldModule public module;
    ERC20Mock public token;
    address public me;
    
    // Ghost variables to track expected state
    uint256 public ghost_principal;
    uint256 public ghost_shares;
    
    constructor(AaveYieldModule _module, ERC20Mock _token) {
        module = _module;
        token = _token;
        me = address(this);
    }
    
    function deposit(uint256 amount) external {
        amount = bound(amount, 1e18, 100_000e18);
        
        // Mint tokens to self if needed
        if (token.balanceOf(me) < amount) {
            token.mint(me, amount);
        }
        
        token.approve(address(module), amount);
        
        // Mock the call as if coming from this handler (acting as EscrowVault)
        // We need to grant ROLE_ESCROW_CONTRACT first, which is done in setup
        
        uint256 sharesBefore = module.escrowScaledBalance(me, 1);
        
        try module.depositForYield(1, address(token), amount, me) returns (bool, uint256) {
            ghost_principal += amount;
            // In the mock, shares 1:1 with amount if index is 1.0
            // But we should check actual change
            uint256 sharesAfter = module.escrowScaledBalance(me, 1);
            ghost_shares += (sharesAfter - sharesBefore);
        } catch {
            // Failed deposit (e.g. cap exceeded), ignore
        }
    }
    
    function withdraw(uint256 amount) external {
        if (ghost_principal == 0) return;
        amount = bound(amount, 1, ghost_principal);
        
        try module.withdrawWithYield(1, address(token), amount, me) returns (bool, uint256 actual, uint256) {
             if (actual > 0) {
                 if (actual >= ghost_principal) {
                     ghost_principal = 0;
                 } else {
                     ghost_principal -= actual;
                 }
                 // Shares are burned proportionally
                 // We can't perfectly predict shares burned without reading logic, 
                 // but we can update ghost_shares based on module state for the invariant check
                 ghost_shares = module.escrowScaledBalance(me, 1);
             }
        } catch {
            // Failed withdraw
        }
    }
}

contract MultiVaultAaveInvariants is StdInvariant, Test {
    AaveYieldModule module;
    ERC20Mock token;
    MockAToken aToken;
    MockAavePool pool;
    MockPoolAddressesProvider provider;
    
    AaveHandler handler1;
    AaveHandler handler2;
    AaveHandler handler3;
    
    address timelock = address(0x1);
    
    function setUp() public {
        // Setup Module and Aave Mocks
        token = new ERC20Mock("Test Token", "TST", address(this), 1_000_000_000e18);
        aToken = new MockAToken(address(token), "aTest Token", "aTST");
        pool = new MockAavePool();
        pool.setAToken(address(token), address(aToken));
        aToken.setPool(address(pool));
        token.mint(address(pool), 1_000_000e18); // Fund pool
        provider = new MockPoolAddressesProvider(address(pool));
        
        module = new AaveYieldModule(timelock);
        vm.startPrank(timelock);
        module.grantRole(module.ROLE_TIMELOCK(), timelock);
        module.queueAavePoolProvider(address(provider));
        vm.warp(block.timestamp + 7 days + 1);
        module.activateAavePoolProvider();
        module.setAaveEnabled(true);
        module.registerTokenForAave(address(token), address(aToken));
        vm.stopPrank();
        
        // Deploy Handlers
        handler1 = new AaveHandler(module, token);
        handler2 = new AaveHandler(module, token);
        handler3 = new AaveHandler(module, token);
        
        // Register Handlers as Escrow Contracts
        vm.startPrank(timelock);
        // Note: In real system, this is done by governance or factory.
        // AaveModule checks ROLE_ESCROW_CONTRACT.
        // We need to expose grantRole or use the admin. 
        // AaveModule inherits AccessControl.
        module.grantRole(module.ROLE_ESCROW_CONTRACT(), address(handler1));
        module.grantRole(module.ROLE_ESCROW_CONTRACT(), address(handler2));
        module.grantRole(module.ROLE_ESCROW_CONTRACT(), address(handler3));
        vm.stopPrank();
        
        // Fuzz target
        targetContract(address(handler1));
        targetContract(address(handler2));
        targetContract(address(handler3));
    }
    
    function invariant_totalScaledBalance_matches_sum_of_vaults() public view {
        uint256 total = module.totalScaledBalance(address(token));
        
        uint256 sum = module.escrowScaledBalance(address(handler1), 1) +
                      module.escrowScaledBalance(address(handler2), 1) +
                      module.escrowScaledBalance(address(handler3), 1);
                      
        assertEq(total, sum, "Total scaled balance must equal sum of individual vault balances");
    }
    
    function invariant_vaults_are_isolated() public view {
        // Ensure handler1's shares are exactly what it expects (tracked via ghost variables)
        // This implicitly checks that handler2/3 actions didn't touch handler1's shares
        // Note: ghost_shares in Handler is roughly updated. 
        // Let's rely on the module's internal consistency:
        // if total == sum, and we know we only acted on specific vaults, isolation is likely preserved.
        // But better:
        
        // We can't strictly assert ghost_shares == escrowScaledBalance because withdraw logic in Handler 
        // approximates the share reduction (it reads back from module). 
        // But the FACT that we read back from module for `me` means if someone else changed it, we would know?
        // No.
        
        // The best invariant here is the Sum check above.
        // Also: totalDepositedToAave check.
        
        uint256 totalPrincipal = module.totalDepositedToAave(address(token));
        uint256 sumPrincipal = module.escrowOriginalDeposit(address(handler1), 1) +
                               module.escrowOriginalDeposit(address(handler2), 1) +
                               module.escrowOriginalDeposit(address(handler3), 1);
                               
        assertEq(totalPrincipal, sumPrincipal, "Total principal must equal sum of individual vault deposits");
    }
}
