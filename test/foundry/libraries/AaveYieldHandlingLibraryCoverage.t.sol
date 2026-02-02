// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../../../contracts/libraries/AaveYieldHandlingLibrary.sol";
import "../../../contracts/interfaces/IYieldGenerationModule.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";

contract AaveYieldHandlingLibraryHarness {
    function getAavePoolAddress(IYieldGenerationModule genModule) external view returns (address) {
        return AaveYieldHandlingLibrary.getAavePoolAddress(genModule);
    }

    function getATokenAddress(IYieldGenerationModule genModule, address token) external view returns (address) {
        return AaveYieldHandlingLibrary.getATokenAddress(genModule, token);
    }

    function getAaveNormalizedIncome(address pool, address token) external view returns (uint256) {
        return AaveYieldHandlingLibrary.getAaveNormalizedIncome(pool, token);
    }

    function handleYieldWithdrawal(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        uint256 scaledShares,
        address aaveYieldLibrary
    ) external returns (AaveYieldHandlingLibrary.WithdrawalResult memory) {
        return AaveYieldHandlingLibrary.handleYieldWithdrawal(
            workflowId, token, amount, genModule, settings, scaledShares, aaveYieldLibrary
        );
    }

    function handleYieldDeposit(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        address aaveYieldLibrary
    ) external returns (AaveYieldHandlingLibrary.DepositResult memory) {
        return AaveYieldHandlingLibrary.handleYieldDeposit(
            workflowId, token, amount, genModule, settings, aaveYieldLibrary
        );
    }
}

contract MockYieldGen is IYieldGenerationModule {
    address public pool;
    address public aToken;
    bool public supported = true;

    function setPool(address _p) external { pool = _p; }
    function setAToken(address _a) external { aToken = _a; }
    function setSupported(bool _s) external { supported = _s; }

    function depositForYield(uint256, address, uint256) external pure returns (bool, uint256) { return (true, 0); }
    function withdrawWithYield(uint256, address, uint256, address) external pure returns (bool, uint256, uint256) { return (true, 0, 0); }
    function calculateYield(uint256, address, address) external pure returns (uint256) { return 0; }
    function isTokenSupported(address) external view returns (bool) { return supported; }
    function getApprovalTarget(address) external view returns (address) { return pool; }
    function moduleName() external pure returns (string memory) { return "Mock"; }
    function moduleVersion() external pure returns (string memory) { return "1.0"; }
    function getAavePoolAddress() external view returns (address) { return pool; }
    function getATokenAddress(address) external view returns (address) { return aToken; }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
}

contract MockPool {
    uint256 public income = 1e27;
    function setIncome(uint256 _i) external { income = _i; }
    function getReserveNormalizedIncome(address) external view returns (uint256) {
        if (income == 0xDEAD) revert("Fail");
        return income;
    }
}

contract MockAaveLibrary {
    function supply(address, address, uint256, address) external pure {}
    function withdraw(address, address, uint256, address) external pure returns (uint256) { return 100; }
}

contract AaveYieldHandlingLibraryCoverageTest is Test {
    AaveYieldHandlingLibraryHarness harness;
    MockYieldGen mockGen;
    MockPool mockPool;
    MockAaveLibrary mockLib;
    
    function setUp() public {
        harness = new AaveYieldHandlingLibraryHarness();
        mockGen = new MockYieldGen();
        mockPool = new MockPool();
        mockLib = new MockAaveLibrary();
    }

    function test_getAavePoolAddress_Success() public {
        mockGen.setPool(address(mockPool));
        assertEq(harness.getAavePoolAddress(mockGen), address(mockPool));
    }

    function test_getATokenAddress_Success() public {
        mockGen.setAToken(address(0xABC));
        assertEq(harness.getATokenAddress(mockGen, address(0x123)), address(0xABC));
    }

    function test_getAaveNormalizedIncome_Success() public {
        mockPool.setIncome(2e27);
        assertEq(harness.getAaveNormalizedIncome(address(mockPool), address(0)), 2e27);
    }

    function test_getAaveNormalizedIncome_TooSmall() public {
        mockPool.setIncome(1e23); // Less than MIN_NORMALIZED_INCOME
        assertEq(harness.getAaveNormalizedIncome(address(mockPool), address(0)), 1e27);
    }

    function test_getAaveNormalizedIncome_Revert() public {
        mockPool.setIncome(0xDEAD); // Trigger revert
        assertEq(harness.getAaveNormalizedIncome(address(mockPool), address(0)), 1e27);
    }

    function test_handleYieldDeposit_EdgeCases() public {
        EscrowSettings memory settings;
        
        // Yield off
        settings.yieldPreset = YieldPreset.OFF;
        AaveYieldHandlingLibrary.DepositResult memory res = harness.handleYieldDeposit(1, address(0), 100, mockGen, settings, address(0));
        assertFalse(res.success);

        settings.yieldPreset = YieldPreset.TO_SENDER;
        
        // genModule == 0
        res = harness.handleYieldDeposit(1, address(0), 100, IYieldGenerationModule(address(0)), settings, address(0));
        assertFalse(res.success);

        // Not supported
        mockGen.setSupported(false);
        res = harness.handleYieldDeposit(1, address(0), 100, mockGen, settings, address(0));
        assertFalse(res.success);
        mockGen.setSupported(true);

        // pool == 0
        res = harness.handleYieldDeposit(1, address(0), 100, mockGen, settings, address(0));
        assertEq(res.failureReason, 3);

        mockGen.setPool(address(mockPool));
        mockGen.setAToken(address(0xABC));

        // Amount too small
        res = harness.handleYieldDeposit(1, address(0), 1e14, mockGen, settings, address(0));
        assertEq(res.failureReason, 8);

        // Success
        res = harness.handleYieldDeposit(1, address(0), 1e18, mockGen, settings, address(mockLib));
        assertTrue(res.success);
        assertEq(res.scaledShares, 1e18);
    }

    function test_handleYieldWithdrawal_EdgeCases() public {
        EscrowSettings memory settings;
        
        // Yield off
        settings.yieldPreset = YieldPreset.OFF;
        AaveYieldHandlingLibrary.WithdrawalResult memory res = harness.handleYieldWithdrawal(1, address(0), 100, mockGen, settings, 100, address(0));
        assertFalse(res.success);

        settings.yieldPreset = YieldPreset.TO_SENDER;

        // genModule == 0
        res = harness.handleYieldWithdrawal(1, address(0), 100, IYieldGenerationModule(address(0)), settings, 100, address(0));
        assertFalse(res.success);

        // aToken == 0
        res = harness.handleYieldWithdrawal(1, address(0), 100, mockGen, settings, 100, address(0));
        assertEq(res.failureReason, 3);

        mockGen.setAToken(address(0xABC));

        // scaledShares == 0
        res = harness.handleYieldWithdrawal(1, address(0), 100, mockGen, settings, 0, address(0));
        assertEq(res.failureReason, 2);

        // pool == 0
        res = harness.handleYieldWithdrawal(1, address(0), 100, mockGen, settings, 100, address(0));
        assertEq(res.failureReason, 3);

        mockGen.setPool(address(mockPool));

        // underlyingToWithdraw == 0
        res = harness.handleYieldWithdrawal(1, address(0), 100, mockGen, settings, 0, address(0));
        assertEq(res.failureReason, 2);

        // Success
        res = harness.handleYieldWithdrawal(1, address(0), 100, mockGen, settings, 100, address(mockLib));
        assertTrue(res.success);
        assertEq(res.actualAmount, 100);
    }

}
