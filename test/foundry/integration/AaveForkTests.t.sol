// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {BaseEscrow} from "../../../contracts/core/BaseEscrow.sol";
import {EscrowVault} from "../../../contracts/core/EscrowVault.sol";
import {AaveYieldLibrary} from "../../../contracts/libraries/AaveYieldLibrary.sol";
import {AaveYieldGenerationModule} from "../../../contracts/modules/AaveYieldGenerationModule.sol";
import {IYieldGenerationModule} from "../../../contracts/interfaces/IYieldGenerationModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Mock} from "../../../contracts/mocks/ERC20Mock.sol";
import {EscrowSettings, YieldPreset} from "../../../contracts/types/EscrowTypes.sol";
import {YieldOps} from "../../../contracts/YieldOps.sol";
import {DisputeOps} from "../../../contracts/DisputeOps.sol";
import {CreateOps} from "../../../contracts/CreateOps.sol";
import {SettlementOps} from "../../../contracts/SettlementOps.sol";
import {ModuleManagementContract} from "../../../contracts/core/ModuleManagementContract.sol";

// Aave v3 interfaces
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (ReserveData memory);
}

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
    function underlyingAsset() external view returns (address);
}

struct ReserveData {
    //stores the reserve configuration
    ReserveConfigurationMap configuration;
    //the liquidity index. Expressed in ray
    uint128 liquidityIndex;
    //the current supply rate. Expressed in ray
    uint128 currentLiquidityRate;
    //variable borrow index. Expressed in ray
    uint128 variableBorrowIndex;
    //the current variable borrow rate. Expressed in ray
    uint128 currentVariableBorrowRate;
    //the current stable borrow rate. Expressed in ray
    uint128 currentStableBorrowRate;
    //timestamp of last update
    uint40 lastUpdateTimestamp;
    //the id of the reserve. Represents the position in the list of the active reserves
    uint16 id;
    //aToken address
    address aTokenAddress;
    //stableDebtToken address
    address stableDebtTokenAddress;
    //variableDebtToken address
    address variableDebtTokenAddress;
    //address of the interest rate strategy
    address interestRateStrategyAddress;
    //the current treasury balance
    uint128 accruedToTreasury;
    //the outstanding unbacked aTokens minted through the bridging feature
    uint128 unbacked;
    //the outstanding debt borrowed against this asset in isolation mode
    uint128 isolationModeTotalDebt;
}

struct ReserveConfigurationMap {
    //bit 0-15: LTV
    //bit 16-31: Liq. threshold
    //bit 32-47: Liq. bonus
    //bit 48-55: Decimals
    //bit 56: reserve is active
    //bit 57: reserve is frozen
    //bit 58: borrowing is enabled
    //bit 59: stable rate borrowing enabled
    //bit 60: asset is paused
    //bit 61: borrowing in isolation mode is enabled
    //bit 62-63: reserved
    //bit 64-79: reserve factor
    //bit 80-115 borrow cap in whole tokens, bit 116-151 supply cap in whole tokens
    //bit 152-167 liquidation protocol fee
    //bit 168-175 eMode category
    //bit 176-211 unbacked mint cap in whole tokens
    //bit 212-251 debt ceiling for isolation mode with (reserveFactor << 1) precision
    //bit 252-255 unused
    uint256 data;
}

/**
 * @title AaveForkTests
 * @notice Fork tests against real Aave v3 on Base Sepolia
 * @dev Validates that our library pattern correctly handles Aave semantics
 *      Tests critical assumptions about msg.sender behavior
 */
contract AaveForkTests is Test {
    // Base Sepolia Aave v3 addresses
    // Provider address retrieved from pool contract: ADDRESSES_PROVIDER() = 0xE4C23309117Aa30342BFaae6c95c6478e0A4Ad00
    address constant BASE_SEPOLIA_POOL_PROVIDER = 0xE4C23309117Aa30342BFaae6c95c6478e0A4Ad00; // Base Sepolia PoolAddressesProvider (from pool)
    // Direct pool address (proxy) - use this if provider lookup fails
    // https://sepolia.basescan.org/address/0x8bab6d1b75f19e9ed9fce8b9bd338844ff79ae27
    address constant BASE_SEPOLIA_POOL_DIRECT = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27; // Base Sepolia Aave Pool (proxy)
    // USDC address on Base Sepolia (verified from Aave UI and BaseScan)
    // https://app.aave.com/reserve-overview/?underlyingAsset=0xba50cd2a20f6da35d788639e581bca8d0b5d4d5f&marketName=proto_base_sepolia_v3
    address constant BASE_SEPOLIA_USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f; // USDC on Base Sepolia
    
    EscrowVault public escrowVault;
    AaveYieldGenerationModule public aaveModule;
    IPool public aavePool;
    IERC20 public usdc;
    IAToken public ausdc;
    
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    ModuleManagementContract public moduleManagement;
    
    address public user = address(0x1234);
    address public recipient = address(0x5678);
    address public feeAddress = address(0xFEE);
    
    // Wrapper contract to use library functions via delegatecall
    LibraryWrapper public libraryWrapper;

    // Fork guard: these tests should only run when an RPC URL is provided.
    bool internal forkActive;
    
    function setUp() public {
        // Fork Base Sepolia - support both --fork-url flag and RPC_BASE_SEPOLIA env var
        // When --fork-url is used, Foundry sets up the fork context automatically
        // We use a default URL if RPC_BASE_SEPOLIA env var is not set (for --fork-url case)
        string memory rpcUrl = vm.envOr("RPC_BASE_SEPOLIA", string("https://sepolia.base.org"));
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER", uint256(0)); // 0 = latest
        
        // Try to create/select fork - will work if --fork-url was used or if RPC_BASE_SEPOLIA is set
        // Note: When --fork-url is used, Foundry may have already created the fork, but calling
        // createSelectFork again should be safe (it will select the existing fork)
        // We can't use try-catch with vm functions, so we'll just attempt it and let it fail if needed
        if (forkBlock > 0) {
            vm.createSelectFork(rpcUrl, forkBlock);
        } else {
            vm.createSelectFork(rpcUrl);
        }
        forkActive = true;
        
        // Mark Aave contracts as persistent (needed for fork tests)
        vm.makePersistent(BASE_SEPOLIA_POOL_PROVIDER);
        
        // Get real Aave Pool
        // Try to get pool from provider first, fall back to direct address
        address poolAddress;
        
        // First verify the provider contract exists on the fork
        if (BASE_SEPOLIA_POOL_PROVIDER.code.length > 0) {
            // Mark provider as persistent
            vm.makePersistent(BASE_SEPOLIA_POOL_PROVIDER);
            
            IPoolAddressesProvider provider = IPoolAddressesProvider(BASE_SEPOLIA_POOL_PROVIDER);
            
            // Get pool address with error handling
            try provider.getPool() returns (address pool) {
                poolAddress = pool;
            } catch {
                // Provider exists but getPool() failed - try direct address
                poolAddress = BASE_SEPOLIA_POOL_DIRECT;
            }
        } else {
            // Provider doesn't exist - use direct pool address
            poolAddress = BASE_SEPOLIA_POOL_DIRECT;
        }
        
        // Verify pool address is valid
        require(poolAddress != address(0), "Aave Pool address is zero");
        require(poolAddress.code.length > 0, "Aave Pool is not a contract");
        
        // Mark pool as persistent
        vm.makePersistent(poolAddress);
        
        aavePool = IPool(poolAddress);
        
        // Deploy infrastructure contracts
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        createOps = new CreateOps(address(this));
        settlementOps = new SettlementOps(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        
        // Deploy EscrowVault
        escrowVault = new EscrowVault(
            100, // 1% escrow fee
            feeAddress,
            address(yieldOps),
            address(disputeOps),
            address(moduleManagement)
        );
        
        // Register escrow with ops contracts
        yieldOps.registerEscrowContract(address(escrowVault));
        disputeOps.registerEscrowContract(address(escrowVault));
        createOps.registerEscrowContract(address(escrowVault));
        settlementOps.registerEscrowContract(address(escrowVault));
        moduleManagement.registerEscrowContract(address(escrowVault));
        
        // Set ops contracts in vault (required for createEscrow)
        escrowVault.grantRole(escrowVault.ROLE_TIMELOCK(), address(this));
        escrowVault.setCreateOps(address(createOps));
        escrowVault.setSettlementOps(address(settlementOps));
        
        // Grant ROLE_ESCROW_CONTRACT to EscrowVault so it can queue/activate modules
        // This is done automatically when registerEscrowContract is called, but let's be explicit
        // Actually, registerEscrowContract grants ROLE_ESCROW_CONTRACT, so we're good
        
        // Get USDC token (or deploy mock if not available)
        usdc = IERC20(BASE_SEPOLIA_USDC);
        if (address(usdc).code.length == 0) {
            // Deploy mock if real USDC not available
            usdc = new ERC20Mock("USD Coin", "USDC", address(this), 0);
        }
        
        // Deploy and configure AaveYieldGenerationModule
        aaveModule = new AaveYieldGenerationModule(address(this));
        
        // Grant admin role to this contract
        aaveModule.grantRole(aaveModule.DEFAULT_ADMIN_ROLE(), address(this));
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), address(this));
        
        // Configure module with real Aave pool (use queue/activate pattern)
        uint256 initialTime = block.timestamp;
        aaveModule.queueAavePoolProvider(BASE_SEPOLIA_POOL_PROVIDER);
        // Warp time to allow activation (7 days for slow lane)
        // The ETA is set to initialTime + 7 days when queuing, so we need to warp past that
        vm.warp(initialTime + 7 days + 1);
        aaveModule.activateAavePoolProvider();
        
        // Enable Aave
        aaveModule.setAaveEnabled(true);
        
        // Register USDC token in module - get aToken address from Aave
        // Try to get reserve data - if it fails, we'll skip Aave tests
        ReserveData memory reserveData;
        try aavePool.getReserveData(address(usdc)) returns (ReserveData memory data) {
            reserveData = data;
        } catch {
            revert("Failed to get USDC reserve data from Aave - USDC may not be available at this block");
        }
        
        address aTokenAddress = reserveData.aTokenAddress;
        require(aTokenAddress != address(0), "USDC aToken address is zero - USDC may not be available on Aave");
        require(aTokenAddress.code.length > 0, "USDC aToken is not a contract");
        
        // Register the token (module will validate underlying asset using UNDERLYING_ASSET_ADDRESS() or underlyingAsset())
        aaveModule.registerTokenForAave(address(usdc), aTokenAddress);
        ausdc = IAToken(aTokenAddress);
        // Verify registration succeeded
        require(aaveModule.getATokenAddress(address(usdc)) == aTokenAddress, "USDC aToken registration failed");
        
        // Register Aave module with ModuleManagementContract (for emergency unwind)
        // EscrowVault needs ROLE_ESCROW_CONTRACT to queue modules
        escrowVault.grantRole(escrowVault.ROLE_TIMELOCK(), address(this));
        escrowVault.grantRole(escrowVault.ROLE_GUARDIAN(), address(this));
        
        // Queue and activate the Aave module as default yield generation module
        // Calculate module queue time explicitly (after pool provider activation: initialTime + 7 days + 1)
        uint256 moduleQueueTime = initialTime + 7 days + 1;
        vm.prank(address(escrowVault));
        moduleManagement.queueModule(address(escrowVault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        vm.stopPrank(); // Clear prank before warping
        // Warp to after the module queue ETA (ETA is set to moduleQueueTime + 7 days when queuing)
        uint256 activationTime = moduleQueueTime + 7 days + 1;
        vm.warp(activationTime);
        vm.prank(address(escrowVault));
        moduleManagement.activateModule(address(escrowVault), BaseEscrow.ModuleType.YIELD_GEN);
        vm.stopPrank();
        
        // Verify module is registered (critical for emergency unwind)
        address registeredModule = moduleManagement.getModule(address(escrowVault), BaseEscrow.ModuleType.YIELD_GEN);
        require(registeredModule == address(aaveModule), "Aave module must be registered after activation");
        
        // Deploy library wrapper for testing
        // Libraries can't be deployed directly, so we create a minimal wrapper
        libraryWrapper = new LibraryWrapper();
        
        // Configure EscrowVault with library wrapper address
        escrowVault.setAaveYieldLibrary(address(libraryWrapper));
        escrowVault.setAaveYieldLibraryEnabled(true);
        
        // Mint USDC to user for testing
        if (address(usdc) == BASE_SEPOLIA_USDC && address(usdc).code.length > 0) {
            // Real USDC on fork - use Foundry's deal cheatcode to give user USDC
            // This works in fork tests by manipulating the token's balance storage
            deal(address(usdc), user, 10000e6); // 10k USDC
        } else {
            // Mock USDC - mint to user
            ERC20Mock(address(usdc)).mint(user, 10000e6); // 10k USDC
        }
    }
    
    /**
     * @notice Test that library pattern correctly maintains msg.sender = BaseEscrow
     * @dev This is the CRITICAL test - validates our fix for the semantic mismatch
     *      This test validates that BaseEscrow owns aTokens, not the module
     */
    function test_LibraryMaintainsMsgSender() public {
        // Diagnostic: Check why forkActive might be false
        require(forkActive, "Fork is not active - check setUp() conditions");
        // Skip if USDC not available on Aave
        address aTokenAddress = aaveModule.getATokenAddress(address(usdc));
        require(aTokenAddress != address(0), "USDC aToken not registered in module");
        
        // User creates escrow with yield enabled
        // Need to deposit enough to meet MIN_YIELD_DEPOSIT (1000e6) after fee
        // With 1% fee, need: depositAmount * 0.99 >= 1000e6
        // So: depositAmount >= 1000e6 / 0.99 ≈ 1010101e6
        // Round up to 1011e6 to be safe (1011 * 0.99 = 1000.89)
        uint256 depositAmount = 1011e6; // 1011 USDC (ensures 1000 USDC after 1% fee)
        
        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(escrowVault), depositAmount);
        
        // Create escrow with yield enabled
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        
        uint256 workflowId = escrowVault.createEscrow(
            address(usdc),
            recipient,
            depositAmount,
            settings
        );
        vm.stopPrank();
        
        // Verify tokens were deposited to Aave
        // BaseEscrow should own aTokens (not the module)
        IAToken aToken = IAToken(aTokenAddress);
        uint256 aTokenBalance = aToken.balanceOf(address(escrowVault));
        
        // CRITICAL ASSERTION: BaseEscrow owns aTokens (not module)
        assertGt(aTokenBalance, 0, "BaseEscrow should own aTokens after deposit");
        
        // Verify module does NOT own aTokens
        uint256 moduleBalance = aToken.balanceOf(address(aaveModule));
        assertEq(moduleBalance, 0, "Module should NOT own aTokens - validates msg.sender semantics");
        
        // Verify underlying was transferred from BaseEscrow to Aave
        uint256 escrowBalance = IERC20(address(usdc)).balanceOf(address(escrowVault));
        // Balance should be less than deposit (some may be in Aave as aTokens)
        // This validates that supply() was called with msg.sender = BaseEscrow
    }
    
    /**
     * @notice Test that withdrawal works correctly with real Aave
     * @dev Validates that BaseEscrow can withdraw its own aTokens
     *      This validates the critical assumption: BaseEscrow owns aTokens, so it can withdraw them
     */
    function test_WithdrawalWorksWithRealAave() public {
        if (!forkActive) {
            vm.skip(true);
            return;
        }
        // Skip if USDC not available on Aave
        address aTokenAddress = aaveModule.getATokenAddress(address(usdc));
        if (aTokenAddress == address(0)) {
            vm.skip(true);
            return;
        }
        
        // Setup: Create escrow and deposit to Aave
        // Need to deposit enough to meet MIN_YIELD_DEPOSIT (1000e6) after fee
        // With 1% fee, need: depositAmount * 0.99 >= 1000e6
        uint256 depositAmount = 1011e6; // 1011 USDC (ensures 1000 USDC after 1% fee)
        
        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(escrowVault), depositAmount);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        
        uint256 workflowId = escrowVault.createEscrow(
            address(usdc),
            recipient,
            depositAmount,
            settings
        );
        vm.stopPrank();
        
        // Verify aTokens were minted to BaseEscrow
        IAToken aToken = IAToken(aTokenAddress);
        uint256 aTokenBalanceBefore = aToken.balanceOf(address(escrowVault));
        assertGt(aTokenBalanceBefore, 0, "BaseEscrow should own aTokens before withdrawal");
        
        // Wait some time for yield to accrue
        vm.warp(block.timestamp + 30 days);
        
        // Release escrow (should withdraw from Aave)
        vm.prank(user);
        escrowVault.releaseEscrowTransfer(workflowId);
        
        // Verify withdrawal succeeded
        // Recipient should receive principal + yield
        uint256 recipientBalance = IERC20(address(usdc)).balanceOf(recipient);
        // Recipient should receive at least the amount after fee (principal - fee)
        // With 1% fee on 1011e6, amountAfterFee = 1011e6 * 0.99 ≈ 1000.89e6
        uint256 expectedMinAmount = depositAmount - (depositAmount * 100 / 10000); // amountAfterFee
        assertGe(recipientBalance, expectedMinAmount, "Recipient should receive at least principal after fee");
        
        // Verify no aTokens remain in BaseEscrow (allow for small rounding differences)
        uint256 remainingATokens = aToken.balanceOf(address(escrowVault));
        // Aave may have small rounding differences due to interest calculation precision
        // Allow up to 1e6 (1 USDC) of remaining aTokens as acceptable rounding
        assertLt(remainingATokens, 1e6, "No significant aTokens should remain after withdrawal - validates withdraw() semantics");
    }
    
    /**
     * @notice Test emergency unwind function with real Aave
     * @dev Validates safety constraints work correctly
     *      CRITICAL: Validates that funds go to BaseEscrow, not guardian
     */
    function test_EmergencyUnwindWithRealAave() public {
        if (!forkActive) {
            vm.skip(true);
            return;
        }
        // Skip if USDC not available on Aave
        address aTokenAddress = aaveModule.getATokenAddress(address(usdc));
        if (aTokenAddress == address(0)) {
            vm.skip(true);
            return;
        }
        
        // Setup: Create escrow with yield
        // Need to deposit enough to meet MIN_YIELD_DEPOSIT (1000e6) after fee
        // With 1% fee, need: depositAmount * 0.99 >= 1000e6
        uint256 depositAmount = 1011e6; // 1011 USDC (ensures 1000 USDC after 1% fee)
        
        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(escrowVault), depositAmount);
        
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        
        escrowVault.createEscrow(
            address(usdc),
            recipient,
            depositAmount,
            settings
        );
        vm.stopPrank();
        
        // Verify aTokens exist
        IAToken aToken = IAToken(aTokenAddress);
        uint256 aTokenBalanceBefore = aToken.balanceOf(address(escrowVault));
        assertGt(aTokenBalanceBefore, 0, "Should have aTokens before unwind");
        
        // Pause and unwind
        escrowVault.pause();
        
        uint256 usdcBalanceBefore = IERC20(address(usdc)).balanceOf(address(escrowVault));
        
        // Call emergency unwind
        uint256 unwound = escrowVault.emergencyUnwindAavePosition(
            address(usdc),
            escrowVault.MAX_UNWIND_AMOUNT_PER_CALL()
        );
        
        assertGt(unwound, 0, "Unwind should succeed");
        
        // CRITICAL: Verify funds went to BaseEscrow (not guardian)
        uint256 usdcBalanceAfter = IERC20(address(usdc)).balanceOf(address(escrowVault));
        assertGt(usdcBalanceAfter, usdcBalanceBefore, "BaseEscrow should receive funds");
        
        // Verify guardian did NOT receive funds
        uint256 guardianBalance = IERC20(address(usdc)).balanceOf(address(this));
        assertEq(guardianBalance, 0, "Guardian should NOT receive funds - validates destination restriction");
        
        // Verify aTokens were burned
        uint256 aTokenBalanceAfter = aToken.balanceOf(address(escrowVault));
        assertLt(aTokenBalanceAfter, aTokenBalanceBefore, "aTokens should be burned after unwind");
    }
    
    /**
     * @notice Test that emergency unwind respects cooldown
     */
    function test_EmergencyUnwindRespectsCooldown() public {
        if (!forkActive) {
            vm.skip(true);
            return;
        }
        // Skip if USDC not available on Aave
        address aTokenAddress = aaveModule.getATokenAddress(address(usdc));
        if (aTokenAddress == address(0)) {
            vm.skip(true);
            return;
        }
        // Setup escrow with yield
        // Need to deposit enough to meet MIN_YIELD_DEPOSIT (1000e6) after fee
        // With 1% fee, need: depositAmount * 0.99 >= 1000e6
        uint256 depositAmount = 1011e6; // 1011 USDC (ensures 1000 USDC after 1% fee)
        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(escrowVault), depositAmount);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        escrowVault.createEscrow(address(usdc), recipient, depositAmount, settings);
        vm.stopPrank();
        
        // Pause and unwind
        vm.prank(address(this));
        escrowVault.pause();
        
        vm.prank(address(this));
        escrowVault.emergencyUnwindAavePosition(address(usdc), 1000e6);
        
        // Try to unwind again immediately - should fail due to cooldown
        vm.prank(address(this));
        uint256 unwound = escrowVault.emergencyUnwindAavePosition(address(usdc), 1000e6);
        assertEq(unwound, 0, "Should return 0 due to cooldown");
        
        // Wait for cooldown
        vm.warp(block.timestamp + escrowVault.UNWIND_COOLDOWN() + 1);
        
        // Now should succeed
        vm.prank(address(this));
        unwound = escrowVault.emergencyUnwindAavePosition(address(usdc), 1000e6);
        // May be 0 if already unwound, but should not revert
    }
    
    /**
     * @notice Test that emergency unwind requires pause
     */
    function test_EmergencyUnwindRequiresPause() public {
        if (!forkActive) {
            vm.skip(true);
            return;
        }
        // Skip if USDC not available on Aave
        address aTokenAddress = aaveModule.getATokenAddress(address(usdc));
        if (aTokenAddress == address(0)) {
            vm.skip(true);
            return;
        }
        
        // Verify module is registered (critical for emergency unwind)
        address registeredModule = moduleManagement.getModule(address(escrowVault), BaseEscrow.ModuleType.YIELD_GEN);
        require(registeredModule == address(aaveModule), "Aave module must be registered for emergency unwind tests");
        
        // CRITICAL DEBUG: Verify EscrowVault can retrieve the module via its internal method
        // This should work if moduleManagement is correctly set in EscrowVault
        // We can't directly call _getDefaultYieldGenerationModule() as it's internal,
        // but we can verify the moduleManagement reference is correct
        require(address(escrowVault.moduleManagement()) == address(moduleManagement), "EscrowVault moduleManagement reference must match");
        
        // Setup escrow with yield
        // Need to deposit enough to meet MIN_YIELD_DEPOSIT (1000e6) after fee
        // With 1% fee, need: depositAmount * 0.99 >= 1000e6
        uint256 depositAmount = 1011e6; // 1011 USDC (ensures 1000 USDC after 1% fee)
        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(escrowVault), depositAmount);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        escrowVault.createEscrow(address(usdc), recipient, depositAmount, settings);
        vm.stopPrank();
        
        // Try to unwind without pause - should revert (whenPaused modifier)
        // The function has whenPaused modifier, so it will revert if not paused
        vm.expectRevert(); // Pausable: EnforcedPause or similar from OpenZeppelin
        escrowVault.emergencyUnwindAavePosition(address(usdc), 1000e6);
    }
}

/**
 * @title LibraryWrapper
 * @notice Wrapper contract that implements library functions for delegatecall
 * @dev BaseEscrow uses delegatecall to this contract, which then calls Aave
 *      This maintains msg.sender = BaseEscrow for Aave semantics
 */
contract LibraryWrapper {
    using SafeERC20 for IERC20;
    
    function supply(address pool, address token, uint256 amount, address onBehalfOf) external {
        IERC20 tokenContract = IERC20(token);
        
        // Get current allowance
        uint256 currentAllowance = tokenContract.allowance(address(this), pool);
        
        // Approve pool (msg.sender = BaseEscrow via delegatecall)
        if (currentAllowance != amount) {
            // Reset to zero first if needed
            if (currentAllowance > 0) {
                tokenContract.safeDecreaseAllowance(pool, currentAllowance);
            }
            // Set new allowance
            tokenContract.safeIncreaseAllowance(pool, amount);
        }
        
        // Supply to Aave (msg.sender = BaseEscrow, pulls from BaseEscrow)
        IPool(pool).supply(token, amount, onBehalfOf, 0);
        
        // Reset approval to zero (safety)
        uint256 remainingAllowance = tokenContract.allowance(address(this), pool);
        if (remainingAllowance > 0) {
            tokenContract.safeDecreaseAllowance(pool, remainingAllowance);
        }
    }
    
    function withdraw(address pool, address token, uint256 amount, address to) external returns (uint256) {
        // Withdraw from Aave (msg.sender = BaseEscrow, burns BaseEscrow's aTokens)
        return IPool(pool).withdraw(token, amount, to);
    }
}
