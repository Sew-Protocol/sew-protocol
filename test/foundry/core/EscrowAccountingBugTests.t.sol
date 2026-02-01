// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/core/EscrowVault.sol';
import '../../../contracts/mocks/ERC20Mock.sol';
import '../../../contracts/YieldOps.sol';
import '../../../contracts/DisputeOps.sol';
import '../../../contracts/core/modules/DefaultResolutionModule.sol';
import '../../../contracts/core/ModuleManagementContract.sol';
import '../../../contracts/libraries/SettingsValidationLibrary.sol';
import '../../../contracts/CreateOps.sol';
import '../../../contracts/SettlementOps.sol';
import '../../../contracts/core/BondCollector.sol';
import '../../../contracts/interfaces/IYieldGenerationModule.sol';

contract MockLossyYieldModule is IYieldGenerationModule {
    uint256 public lossAmount;
    bool public tokenSupported = true;

    function setLoss(uint256 _loss) external {
        lossAmount = _loss;
    }

    function depositForYield(uint256, address, uint256) external pure returns (bool, uint256) {
        return (true, 0);
    }

    function withdrawWithYield(uint256, address, uint256 originalAmount) external view returns (bool, uint256, uint256) {
        return (true, originalAmount - lossAmount, 0);
    }

    function calculateYield(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function isTokenSupported(address) external view returns (bool) {
        return tokenSupported;
    }

    function getApprovalTarget(address) external pure returns (address) {
        return address(0);
    }

    function moduleName() external pure returns (string memory) {
        return "MockLossyYieldModule";
    }

    function moduleVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    function getAavePoolAddress() external pure returns (address) {
        return address(0);
    }

    function getATokenAddress(address) external pure returns (address) {
        return address(0);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IYieldGenerationModule).interfaceId;
    }
}

contract EscrowAccountingBugTests is Test {
    EscrowVault public vault;
    YieldOps public yieldOps;
    DisputeOps public disputeOps;
    ModuleManagementContract public mm;
    CreateOps public createOps;
    SettlementOps public settlementOps;
    BondCollector public bondCollector;
    DefaultResolutionModule public resolutionModule;
    MockLossyYieldModule public yieldGen;
    
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
        mm = new ModuleManagementContract(address(this));
        createOps = new CreateOps(address(this));
        settlementOps = new SettlementOps(address(this));
        bondCollector = new BondCollector(address(this));
        resolutionModule = new DefaultResolutionModule(address(this), resolver);
        yieldGen = new MockLossyYieldModule();

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

        (uint256 principalHeld, uint256 feesCollected, uint256 contractBalance, ) = vault.getAccountingBreakdown(address(token));
        
        // Delta should be 0 because:
        // actual (10e18 fees) == expected (0 principal + 10e18 fees)
        // The loss of 100e18 is "written off" by reducing totalHeldInEscrowPerToken by 990e18 (the full principal)
        // while only 890e18 was actually transferred out.
        // Wait, if 890e18 was transferred out, and we started with 1000e18, we have 110e18 left.
        // If principalHeld is 0 and feesCollected is 10e18, then expected is 10e18.
        // actual (110e18) > expected (10e18) -> delta is 100e18 (THE LOSS).
        
        int256 delta = int256(contractBalance) - int256(principalHeld + feesCollected);
        assertEq(delta, int256(loss), "Accounting delta should reflect the loss as an 'unaccounted' balance");
    }
}
