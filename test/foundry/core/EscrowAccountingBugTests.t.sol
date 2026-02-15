// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/core/EscrowVaultAnalytics.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/ops/YieldOps.sol';
import '../../../contracts/ops/DisputeOps.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/core/ModuleSnapshotRegistry.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/ops/CreateOps.sol';
import '../../../contracts/ops/SettlementOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/interfaces/IYieldModule.sol';
import '../../../contracts/types/YieldPresets.sol';

contract MockYieldModuleWithLoss is IYieldModule {
    using SafeERC20 for IERC20;
    
    uint256 public lossAmount;
    mapping(address escrow => mapping(uint256 escrowId => YieldPosition)) public positions;
    
    struct YieldPosition {
        address token;
        uint256 principalDeposited;
    }

    function setLoss(uint256 _loss) external {
        lossAmount = _loss;
    }

    function initializeYield(
        uint256 escrowId,
        address token,
        uint256 amount,
        YieldPreset yieldMode
    ) external returns (uint256 accepted) {
        // Accept the full amount (or reduced by loss if simulating fee-on-transfer)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        positions[msg.sender][escrowId] = YieldPosition({
            token: token,
            principalDeposited: amount
        });
        
        emit YieldInitialized(escrowId, token, amount, yieldMode);
        return amount;
    }

    function unwindToEscrow(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external returns (uint256 principalOut, uint256 yieldOut) {
        YieldPosition memory pos = positions[msg.sender][escrowId];
        require(pos.token == token, "TokenMismatch");
        
        // Return funds with loss applied
        uint256 principal = pos.principalDeposited;
        uint256 returnAmount = principal > lossAmount ? principal - lossAmount : 0;
        
        if (returnAmount > 0) {
            IERC20(token).safeTransfer(msg.sender, returnAmount);
        }
        
        delete positions[msg.sender][escrowId];
        
        uint256 yield = 0; // No yield in this mock
        emit YieldWithdrawn(escrowId, token, principal - lossAmount, yield);
        
        return (principal - lossAmount, yield);
    }

    function emergencyUnwind(
        uint256 escrowId,
        address token,
        uint256 principalExpected
    ) external returns (uint256 recovered) {
        YieldPosition memory pos = positions[msg.sender][escrowId];
        require(pos.token == token, "TokenMismatch");
        
        uint256 principal = pos.principalDeposited;
        uint256 returnAmount = principal > lossAmount ? principal - lossAmount : 0;
        
        if (returnAmount > 0) {
            IERC20(token).safeTransfer(msg.sender, returnAmount);
        }
        
        delete positions[msg.sender][escrowId];
        
        require(returnAmount > 0, "EmergencyUnwindFailed");
        emit EmergencyUnwindExecuted(escrowId, token, returnAmount, keccak256("emergency_unwind"));
        
        return returnAmount;
    }

    function canHandle(
        address token,
        YieldPreset mode,
        uint256 amount
    ) external pure returns (bool supported, bytes32 reasonCode) {
        return (true, 0x0);
    }

    function getModuleInfo()
        external pure returns (string memory name, string memory version, bytes32 protocolId) {
        return ("MockYieldModuleWithLoss", "1.0.0", keccak256("mock-v1"));
    }
}

contract EscrowAccountingBugTests is Test {
    EscrowVault public vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleSnapshotRegistry public mm;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    DefaultResolutionModule public resolutionModule;
    MockYieldModuleWithLoss public yieldGen;
    
    ERC20Mock public token;

    address public feeAddress = address(0xFEE);
    address public buyer = address(0x1001);
    address public seller = address(0x1002);
    address public resolver = address(0x1234);

    uint256 constant FEE_BPS = 100; // 1%

    function setUp() public {
        token = new ERC20Mock("Token", "TKN", address(this), 1000000e18);

        yieldOps = new YieldOps(address(this));
        disputeOps = new DisputeOps(address(this));
        mm = new ModuleSnapshotRegistry(address(this));
        createOps = new CreateOps(address(this));
        settlementOps = new SettlementOps(address(this));
        bondCollector = new BondCollector(address(this));
        resolutionModule = new DefaultResolutionModule(address(this), resolver);
        yieldGen = new MockYieldModuleWithLoss();

        vault = new EscrowVault(FEE_BPS, feeAddress, address(yieldOps), address(disputeOps), address(mm));

        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(resolutionModule));
        
        // Set default yield gen module via governance
        mm.queueModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN, address(yieldGen));
        vm.warp(block.timestamp + 8 days);
        mm.activateModule(address(vault), BaseEscrow.ModuleType.YIELD_GEN);

        token.transfer(buyer, 100000e18);
    }

    /**
     * @notice Test if principal loss in yield module is correctly accounted for.
     * Before the fix, totalHeldInEscrowPerToken was reduced by only the actual withdrawn amount,
     * leaving a remainder in accounting that looked like an excess, but was actually lost funds.
     * After the fix, totalHeldInEscrowPerToken is reduced by the full principal, correctly writing off the loss.
     */
    function test_accounting_correctness_on_yield_loss() public {
        uint256 amount = 1000e18;
        uint256 expectedFee = amount * FEE_BPS / 10000;
        uint256 principal = amount - expectedFee;

        // 1. Create escrow with yield enabled
        vm.startPrank(buyer);
        token.approve(address(vault), amount);
        
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.yieldPreset = YieldPreset.TO_SENDER;
        
        uint256 wid = vault.createEscrow(address(token), seller, amount, settings);
        vm.stopPrank();

        // Simulate loss in yield module
        uint256 loss = 100e18;
        yieldGen.setLoss(loss);

        uint256 heldBefore = vault.totalHeldInEscrowPerToken(address(token));
        assertEq(heldBefore, principal, "Held before mismatch");

        // 2. Release escrow - this will trigger _handleYieldAndGetActualAmount which returns principal - loss
        vm.prank(buyer);
        vault.releaseEscrowTransfer(wid);

        uint256 heldAfter = vault.totalHeldInEscrowPerToken(address(token));
        
        // With the fix, heldAfter MUST be 0 because we reduce by the full principal 'amountAfterFee' (990e18)
        assertEq(heldAfter, 0, "totalHeldInEscrowPerToken should be 0 after full release even with loss");

        (uint256 principalHeld, uint256 feesCollected, uint256 contractBalance, ) = EscrowVaultAnalytics(address(vault)).getAccountingBreakdown(address(token));
        
        // Delta should be 0 because:
        // In v2.5 architecture, lost funds stay in the yield module - they are NOT returned to escrow
        // contractBalance = 10e18 (the fee that was kept in escrow: 1000e18 - 990e18 transferred to module)
        // principalHeld = 0 (reduced by full principal 990e18)
        // feesCollected = 10e18
        // expected = 0 + 10e18 + 0 = 10e18
        // delta = 10e18 - 10e18 = 0
        // The loss of 100e18 remains in the yield module, NOT in the escrow contract
        
        uint256 expected = principalHeld + feesCollected + vault.totalClaimableAssets(address(token));
        int256 delta = int256(contractBalance) - int256(expected);
        assertEq(delta, 0, "Delta should be 0 since loss stays in yield module");
    }
}
