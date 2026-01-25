// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "../../../lib/forge-std/src/Test.sol";

import {EscrowVault} from "../../../contracts/core/EscrowVault.sol";
import {BaseEscrow} from "../../../contracts/core/BaseEscrow.sol";
import {ModuleManagementContract} from "../../../contracts/core/ModuleManagementContract.sol";
import {DefaultResolutionModule} from "../../../contracts/core/modules/DefaultResolutionModule.sol";
import {DefaultYieldDistributionModule} from "../../../contracts/modules/DefaultYieldDistributionModule.sol";
import {YieldOps} from "../../../contracts/YieldOps.sol";
import {DisputeOps} from "../../../contracts/DisputeOps.sol";
import {CreateOps} from "../../../contracts/CreateOps.sol";
import {SettlementOps} from "../../../contracts/SettlementOps.sol";
import {BondCollector} from "../../../contracts/core/BondCollector.sol";
import {ERC20Mock} from "../../../contracts/mocks/ERC20Mock.sol";
import {EscrowSettings} from "../../../contracts/types/EscrowTypes.sol";
import {YieldPreset} from "../../../contracts/types/YieldPresets.sol";
import {IYieldGenerationModule} from "../../../contracts/interfaces/IYieldGenerationModule.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Minimal "Aave-like" pool for testing per-escrow scaled shares accounting.
 *
 * - supply(): pulls underlying from msg.sender
 * - withdraw(): burns caller's scaled shares and transfers underlying to `to`
 * - getReserveNormalizedIncome(): returns a per-asset RAY index
 *
 * The pool tracks scaled shares internally per (account, asset).
 */
contract MockAavePoolNormalizedIncome {
    using SafeERC20 for IERC20;

    uint256 internal constant RAY = 1e27;

    mapping(address => uint256) public incomeRay; // asset => normalized income (RAY)
    mapping(address => mapping(address => uint256)) public scaledShares; // account => asset => scaled shares

    function setIncomeRay(address asset, uint256 newIncomeRay) external {
        require(newIncomeRay > 0, "income=0");
        incomeRay[asset] = newIncomeRay;
    }

    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        uint256 v = incomeRay[asset];
        return v == 0 ? RAY : v;
    }

    function supply(address asset, uint256 amount, address /* onBehalfOf */, uint16) external {
        uint256 idx = incomeRay[asset];
        if (idx == 0) idx = RAY;

        // Pull underlying from msg.sender (Aave v3 semantics)
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Mint scaled shares to msg.sender (the holder of aTokens is msg.sender in library pattern)
        uint256 scaled = (amount * RAY) / idx;
        scaledShares[msg.sender][asset] += scaled;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 idx = incomeRay[asset];
        if (idx == 0) idx = RAY;

        // Convert underlying amount to scaled shares to burn
        uint256 scaledToBurn = (amount * RAY) / idx;
        uint256 bal = scaledShares[msg.sender][asset];
        require(bal >= scaledToBurn, "scaled/insufficient");
        scaledShares[msg.sender][asset] = bal - scaledToBurn;

        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }
}

/**
 * @dev A minimal config-only "Aave module" for BaseEscrow library pattern tests.
 * It supplies pool + aToken addresses and claims token support.
 */
contract MockAaveConfigModule is ERC165, IYieldGenerationModule {
    address public pool;
    address public aToken;

    constructor(address pool_, address aToken_) {
        pool = pool_;
        aToken = aToken_;
    }

    // Not used in library pattern tests
    function depositForYield(uint256, address, uint256) external pure override returns (bool, uint256) {
        return (true, 0);
    }
    function withdrawWithYield(uint256, address, uint256) external pure override returns (bool, uint256, uint256) {
        return (true, 0, 0);
    }
    function calculateYield(uint256, address) external pure override returns (uint256) {
        return 0;
    }
    function getApprovalTarget(address) external view override returns (address) {
        return pool;
    }
    function isTokenSupported(address) external pure override returns (bool) {
        return true;
    }
    function moduleName() external pure override returns (string memory) {
        return "MockAaveConfig";
    }
    function moduleVersion() external pure override returns (string memory) {
        return "1.0.0";
    }
    function getAavePoolAddress() external view override returns (address) {
        return pool;
    }
    function getATokenAddress(address) external view override returns (address) {
        return aToken;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IYieldGenerationModule).interfaceId || super.supportsInterface(interfaceId);
    }
}

/**
 * @dev Delegatecall target used by BaseEscrow's library pattern.
 */
contract AaveLibraryWrapper2 {
    using SafeERC20 for IERC20;

    function supply(address pool, address token, uint256 amount, address onBehalfOf) external {
        IERC20 tokenContract = IERC20(token);

        uint256 currentAllowance = tokenContract.allowance(address(this), pool);
        if (currentAllowance != amount) {
            if (currentAllowance > 0) {
                tokenContract.safeDecreaseAllowance(pool, currentAllowance);
            }
            tokenContract.safeIncreaseAllowance(pool, amount);
        }

        // Aave semantics: onBehalfOf is ignored by our mock pool; msg.sender is the escrow
        MockAavePoolNormalizedIncome(pool).supply(token, amount, onBehalfOf, 0);

        // Reset approval
        uint256 remaining = tokenContract.allowance(address(this), pool);
        if (remaining > 0) {
            tokenContract.safeDecreaseAllowance(pool, remaining);
        }
    }

    function withdraw(address pool, address token, uint256 amount, address to) external returns (uint256) {
        return MockAavePoolNormalizedIncome(pool).withdraw(token, amount, to);
    }
}

contract AaveLibraryMultiEscrowTest is Test {
    uint256 internal constant RAY = 1e27;

    EscrowVault internal vault;
    ModuleManagementContract internal mm;
    YieldOps internal yieldOps;
    DisputeOps internal disputeOps;
    CreateOps internal createOps;
    SettlementOps internal settlementOps;
    BondCollector internal bondCollector;
    DefaultResolutionModule internal rm;
    DefaultYieldDistributionModule internal yieldDist;

    ERC20Mock internal token;
    MockAavePoolNormalizedIncome internal pool;
    MockAaveConfigModule internal configModule;
    AaveLibraryWrapper2 internal wrapper;

    address internal feeAddress = address(0xFEE);
    address internal resolver = address(0xBEEF);
    address internal buyer1 = address(0x1001);
    address internal buyer2 = address(0x1002);
    address internal seller1 = address(0x2001);
    address internal seller2 = address(0x2002);

    function setUp() public {
        token = new ERC20Mock("T", "T", address(this), 0);
        pool = new MockAavePoolNormalizedIncome();
        pool.setIncomeRay(address(token), RAY); // start at 1.0

        // Dummy aToken address (not used in v2 accounting path)
        address dummyAToken = address(0xA7100);
        configModule = new MockAaveConfigModule(address(pool), dummyAToken);
        wrapper = new AaveLibraryWrapper2();

        // Core system
        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        createOps = new CreateOps(address(this));
        settlementOps = new SettlementOps(address(this));
        bondCollector = new BondCollector(address(this));
        mm = new ModuleManagementContract(address(this));
        yieldDist = new DefaultYieldDistributionModule();

        vault = new EscrowVault(100, feeAddress, address(yieldOps), address(disputeOps), address(mm));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        createOps.grantRole(createOps.ROLE_TIMELOCK(), address(this));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));

        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        rm = new DefaultResolutionModule(address(this), resolver);
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setResolutionModule(address(rm));

        // Set default yield gen + dist
        vm.prank(address(vault));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(configModule));
        vm.prank(address(vault));
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST, address(yieldDist));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(address(vault));
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);
        vm.prank(address(vault));
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_DIST);

        // Module pattern is now used directly (no delegatecall library needed)
        vault.setYieldProtocolFeeBps(0);

        // Fund buyers and pool liquidity
        token.mint(buyer1, 1000 ether);
        token.mint(buyer2, 1000 ether);
        token.mint(address(pool), 10_000 ether);
    }

    function test_two_concurrent_yield_escrows_withdraw_independently() public {
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.TO_SENDER,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });

        // Create two escrows with yield enabled (same token)
        vm.startPrank(buyer1);
        token.approve(address(vault), 100 ether);
        uint256 w1 = vault.createEscrow(address(token), seller1, 100 ether, settings);
        vm.stopPrank();

        vm.startPrank(buyer2);
        token.approve(address(vault), 200 ether);
        uint256 w2 = vault.createEscrow(address(token), seller2, 200 ether, settings);
        vm.stopPrank();

        // Accrue yield: bump normalized income to 1.10
        pool.setIncomeRay(address(token), (RAY * 110) / 100);

        // Release escrow 1; should succeed and not break escrow 2.
        uint256 seller1Before = token.balanceOf(seller1);
        vm.prank(buyer1);
        vault.releaseEscrowTransfer(w1);
        uint256 seller1After = token.balanceOf(seller1);
        assertGt(seller1After, seller1Before, "seller1 should get paid");

        // Release escrow 2; should still succeed independently.
        uint256 seller2Before = token.balanceOf(seller2);
        vm.prank(buyer2);
        vault.releaseEscrowTransfer(w2);
        uint256 seller2After = token.balanceOf(seller2);
        assertGt(seller2After, seller2Before, "seller2 should get paid");

        // Basic sanity: pool should have burned scaled shares for the vault.
        uint256 remainingScaled = pool.scaledShares(address(vault), address(token));
        assertEq(remainingScaled, 0, "vault should have no remaining scaled shares");
    }
}

