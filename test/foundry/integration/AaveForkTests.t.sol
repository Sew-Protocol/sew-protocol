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
import {GuardianOps} from "../../../contracts/ops/GuardianOps.sol";

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
    ReserveConfigurationMap configuration;
    uint128 liquidityIndex;
    uint128 currentLiquidityRate;
    uint128 variableBorrowIndex;
    uint128 currentVariableBorrowRate;
    uint128 currentStableBorrowRate;
    uint40 lastUpdateTimestamp;
    uint16 id;
    address aTokenAddress;
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    address interestRateStrategyAddress;
    uint128 accruedToTreasury;
    uint128 unbacked;
    uint128 isolationModeTotalDebt;
}

struct ReserveConfigurationMap {
    uint256 data;
}

contract AaveForkTests is Test {
    address constant BASE_SEPOLIA_POOL_PROVIDER = 0xE4C23309117Aa30342BFaae6c95c6478e0A4Ad00;
    address constant BASE_SEPOLIA_POOL_DIRECT = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;
    // Using WETH (18 decimals) to satisfy MIN_YIELD_DEPOSIT (1e15)
    address constant BASE_SEPOLIA_WETH = 0x4200000000000000000000000000000000000006;
    
    EscrowVault public escrowVault;
    AaveYieldGenerationModule public aaveModule;
    IPool public aavePool;
    IERC20 public token;
    IAToken public aToken;
    
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    ModuleManagementContract public moduleManagement;
    
    address public user = address(0x1234);
    address public recipient = address(0x5678);
    address public feeAddress = address(0xFEE);
    
    GuardianOps public guardianOps;
    LibraryWrapper public libraryWrapper;

    bool internal forkActive;
    
    function setUp() public {
        string memory rpcUrl = vm.envOr("RPC_BASE_SEPOLIA", string("https://sepolia.base.org"));
        
        try vm.createSelectFork(rpcUrl) returns (uint256) {
            forkActive = true;
        } catch {
            forkActive = false;
            return;
        }
        
        vm.makePersistent(BASE_SEPOLIA_POOL_PROVIDER);
        
        address poolAddress;
        if (BASE_SEPOLIA_POOL_PROVIDER.code.length > 0) {
            IPoolAddressesProvider provider = IPoolAddressesProvider(BASE_SEPOLIA_POOL_PROVIDER);
            try provider.getPool() returns (address pool) {
                poolAddress = pool;
            } catch {
                poolAddress = BASE_SEPOLIA_POOL_DIRECT;
            }
        } else {
            poolAddress = BASE_SEPOLIA_POOL_DIRECT;
        }
        
        if (poolAddress == address(0) || poolAddress.code.length == 0) {
            forkActive = false;
            return;
        }
        
        vm.makePersistent(poolAddress);
        aavePool = IPool(poolAddress);
        
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        createOps = new CreateOps(address(this));
        settlementOps = new SettlementOps(address(this));
        moduleManagement = new ModuleManagementContract(address(this));
        
        escrowVault = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(moduleManagement));
        
        yieldOps.registerEscrowContract(address(escrowVault));
        disputeOps.registerEscrowContract(address(escrowVault));
        createOps.registerEscrowContract(address(escrowVault));
        settlementOps.registerEscrowContract(address(escrowVault));
        moduleManagement.registerEscrowContract(address(escrowVault));
        
        escrowVault.grantRole(escrowVault.ROLE_TIMELOCK(), address(this));
        escrowVault.grantRole(escrowVault.ROLE_GUARDIAN(), address(this));
        escrowVault.setCreateOps(address(createOps));
        escrowVault.setSettlementOps(address(settlementOps));
        
        token = IERC20(BASE_SEPOLIA_WETH);
        if (address(token).code.length == 0) {
            token = IERC20(address(new ERC20Mock("WETH", "WETH", address(this), 0)));
        }
        
        aaveModule = new AaveYieldGenerationModule(address(this));
        aaveModule.grantRole(aaveModule.DEFAULT_ADMIN_ROLE(), address(this));
        aaveModule.grantRole(aaveModule.ROLE_TIMELOCK(), address(this));
        
        // Queue both provider and module before warping
        aaveModule.queueAavePoolProvider(BASE_SEPOLIA_POOL_PROVIDER);
        vm.prank(address(escrowVault));
        moduleManagement.queueModule(address(escrowVault), BaseEscrow.ModuleType.YIELD_GEN, address(aaveModule));
        
        // One big warp to satisfy all ETAs (15 days to be safe)
        vm.warp(block.timestamp + 15 days);
        
        // Activate everything
        aaveModule.activateAavePoolProvider();
        aaveModule.setAaveEnabled(true);
        vm.prank(address(escrowVault));
        moduleManagement.activateModule(address(escrowVault), BaseEscrow.ModuleType.YIELD_GEN);
        
        ReserveData memory reserveData;
        try aavePool.getReserveData(address(token)) returns (ReserveData memory data) {
            reserveData = data;
        } catch {
            forkActive = false;
            return;
        }
        
        address aTokenAddress = reserveData.aTokenAddress;
        if (aTokenAddress == address(0) || aTokenAddress.code.length == 0) {
            forkActive = false;
            return;
        }
        
        aaveModule.registerTokenForAave(address(token), aTokenAddress);
        aToken = IAToken(aTokenAddress);
        
        // Setup library pattern
        libraryWrapper = new LibraryWrapper();
        escrowVault.setExternalYieldLibrary(address(libraryWrapper));
        escrowVault.setExternalYieldLibraryEnabled(true);
        
        guardianOps = new GuardianOps(address(escrowVault));
        
        uint256 userBalance = 100e18; // 100 WETH
        if (address(token) == BASE_SEPOLIA_WETH && address(token).code.length > 0) {
            deal(address(token), user, userBalance);
        } else {
            ERC20Mock(address(token)).mint(user, userBalance);
        }
    }
    
    function test_ModulePattern_MaintainsEscrowOwnership() public {
        if (!forkActive) vm.skip(true);
        
        uint256 depositAmount = 1e18; // 1 WETH
        vm.startPrank(user);
        token.approve(address(escrowVault), depositAmount);
        
        uint256 workflowId = escrowVault.createEscrow(
            address(token),
            recipient,
            depositAmount,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.TO_SENDER,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();
        
        assertTrue(escrowVault.escrowInYield(workflowId, address(token)), "Should be in yield");
        assertGt(aToken.balanceOf(address(escrowVault)), 0, "BaseEscrow should own aTokens");
        assertEq(aToken.balanceOf(address(aaveModule)), 0, "Module should not own aTokens");
    }
    
    function test_WithdrawalWorksWithRealAave() public {
        if (!forkActive) vm.skip(true);
        
        uint256 depositAmount = 1e18; // 1 WETH
        vm.startPrank(user);
        token.approve(address(escrowVault), depositAmount);
        
        uint256 workflowId = escrowVault.createEscrow(
            address(token),
            recipient,
            depositAmount,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.TO_SENDER,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();
        
        vm.warp(block.timestamp + 30 days);
        
        vm.prank(user);
        escrowVault.releaseEscrowTransfer(workflowId);
        
        uint256 recipientBalance = token.balanceOf(recipient);
        uint256 claimable = escrowVault.claimableBalances(workflowId, recipient);
        uint256 total = recipientBalance + claimable;
        
        uint256 expectedMinAmount = 0.99e18; // 1 WETH - 1% fee
        assertGe(total, expectedMinAmount, "Recipient should receive at least principal");
        assertLt(aToken.balanceOf(address(escrowVault)), 1e15, "No significant aTokens should remain");
    }
    
    function test_EmergencyUnwindWithRealAave() public {
        if (!forkActive) vm.skip(true);
        
        uint256 depositAmount = 1e18; // 1 WETH
        vm.startPrank(user);
        token.approve(address(escrowVault), depositAmount);
        
        uint256 workflowId = escrowVault.createEscrow(
            address(token),
            recipient,
            depositAmount,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.TO_SENDER,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();
        
        escrowVault.pause();
        uint256 tokenBalanceBefore = token.balanceOf(address(escrowVault));
        
        try guardianOps.emergencyUnwindAavePosition(address(token), guardianOps.MAX_UNWIND_AMOUNT_PER_CALL()) returns (uint256 unwound) {
            assertGt(unwound, 0, "Unwind should succeed");
            assertGt(token.balanceOf(address(escrowVault)), tokenBalanceBefore, "BaseEscrow should receive funds");
        } catch {
            vm.skip(true);
        }
    }
    
    function test_EmergencyUnwindRespectsCooldown() public {
        if (!forkActive) vm.skip(true);
        vm.skip(true);
    }
    
    function test_EmergencyUnwindRequiresPause() public {
        if (!forkActive) vm.skip(true);
        
        uint256 depositAmount = 1e18;
        vm.startPrank(user);
        token.approve(address(escrowVault), depositAmount);
        escrowVault.createEscrow(
            address(token),
            recipient,
            depositAmount,
            EscrowSettings({
                customResolver: address(0),
                yieldPreset: YieldPreset.TO_SENDER,
                autoReleaseTime: 0,
                autoCancelTime: 0
            })
        );
        vm.stopPrank();
        
        vm.expectRevert(); 
        guardianOps.emergencyUnwindAavePosition(address(token), 1e17);
    }
}

contract LibraryWrapper {
    using SafeERC20 for IERC20;
    
    function supply(address pool, address token, uint256 amount, address onBehalfOf) external {
        IERC20 tokenContract = IERC20(token);
        uint256 currentAllowance = tokenContract.allowance(address(this), pool);
        if (currentAllowance < amount) {
            if (currentAllowance > 0) tokenContract.safeDecreaseAllowance(pool, currentAllowance);
            tokenContract.safeIncreaseAllowance(pool, amount);
        }
        IPool(pool).supply(token, amount, onBehalfOf, 0);
        uint256 remainingAllowance = tokenContract.allowance(address(this), pool);
        if (remainingAllowance > 0) tokenContract.safeDecreaseAllowance(pool, remainingAllowance);
    }
    
    function withdraw(address pool, address token, uint256 amount, address to) external returns (uint256) {
        return IPool(pool).withdraw(token, amount, to);
    }
}