// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../../contracts/libraries/YieldHandlingLibrary.sol';
import '../../../contracts/libraries/YieldPresetLibrary.sol';
import '../../../contracts/libraries/YieldDistributionLibrary.sol';
import '../../../contracts/types/YieldPresets.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/mocks/ERC20Mock.sol';

contract LibraryHarness {
    using SafeERC20 for IERC20;

    // YieldHandlingLibrary wrappers
    function withdrawFullWithYield(
        IYieldGenerationModule genModule,
        uint256 workflowId,
        address token,
        uint256 amount
    ) external returns (uint256 actualAmount, uint256 yield) {
        return YieldHandlingLibrary.withdrawFullWithYield(genModule, workflowId, token, amount);
    }

    function distributeYield(
        IYieldDistributionModule distModule,
        uint256 workflowId,
        address token,
        uint256 yieldAmount
    ) external {
        YieldHandlingLibrary.distributeYield(distModule, workflowId, token, yieldAmount);
    }

    function getApprovalTarget(
        IYieldGenerationModule genModule,
        address token
    ) external view returns (address approvalTarget) {
        return YieldHandlingLibrary.getApprovalTarget(genModule, token);
    }

    // YieldPresetLibrary wrappers
    function deriveDistributionData(
        YieldPreset preset,
        address sender,
        address recipient
    ) external pure returns (bytes memory) {
        return YieldPresetLibrary.deriveDistributionData(preset, sender, recipient);
    }

    function isYieldEnabled(YieldPreset preset) external pure returns (bool) {
        return YieldPresetLibrary.isYieldEnabled(preset);
    }

    function validatePresetParams(
        YieldPreset preset,
        address sender,
        address recipient
    ) external pure {
        YieldPresetLibrary.validatePresetParams(preset, sender, recipient);
    }

    // YieldDistributionLibrary wrappers
    function validateYieldDistribution(
        address[] memory recipients,
        uint256[] memory percentages
    ) external pure {
        YieldDistributionLibrary.validateYieldDistribution(recipients, percentages);
    }

    function decodeYieldDistribution(
        bytes memory data
    ) external pure returns (address[] memory recipients, uint256[] memory percentages) {
        return YieldDistributionLibrary.decodeYieldDistribution(data);
    }

    function distributeYieldFallback(
        address token,
        uint256 yieldAmount,
        address[] memory recipients,
        uint256[] memory percentages,
        address feeAddress
    ) external returns (uint256 totalDistributed) {
        return YieldDistributionLibrary.distributeYieldFallback(token, yieldAmount, recipients, percentages, feeAddress);
    }
}

contract LibraryCoverageTest is Test {
    ERC20Mock public token;
    MockGenModule public genModule;
    MockDistModule public distModule;
    LibraryHarness public harness;

    function setUp() public {
        token = new ERC20Mock('Test', 'TEST', address(this), 10000e18);
        genModule = new MockGenModule();
        distModule = new MockDistModule();
        harness = new LibraryHarness();
    }

    // ============ YieldHandlingLibrary Tests ============

    function test_YieldHandling_withdrawFullWithYield_NoModule() public {
        (uint256 actual, uint256 yield) = harness.withdrawFullWithYield(
            IYieldGenerationModule(address(0)),
            1,
            address(token),
            100
        );
        assertEq(actual, 100);
        assertEq(yield, 0);
    }

    function test_YieldHandling_withdrawFullWithYield_Success() public {
        genModule.setWithdrawResult(true, 110, 10);
        (uint256 actual, uint256 yield) = harness.withdrawFullWithYield(
            genModule,
            1,
            address(token),
            100
        );
        assertEq(actual, 110);
        assertEq(yield, 10);
    }

    function test_YieldHandling_withdrawFullWithYield_Failure() public {
        genModule.setWithdrawResult(false, 0, 0);
        (uint256 actual, uint256 yield) = harness.withdrawFullWithYield(
            genModule,
            1,
            address(token),
            100
        );
        assertEq(actual, 100);
        assertEq(yield, 0);
    }

    function test_YieldHandling_distributeYield_NoModule() public {
        vm.expectRevert("No yield distribution module");
        harness.distributeYield(
            IYieldDistributionModule(address(0)),
            1,
            address(token),
            100
        );
    }

    function test_YieldHandling_distributeYield_Success() public {
        token.mint(address(harness), 100); // Give tokens to harness
        
        distModule.setDistributeResult(true);
        harness.distributeYield(
            distModule,
            1,
            address(token),
            100
        );
        assertEq(token.balanceOf(address(distModule)), 100);
    }

    function test_YieldHandling_distributeYield_Failure() public {
        token.mint(address(harness), 100); // Give tokens to harness
        distModule.setDistributeResult(false);
        vm.expectRevert("Yield distribution failed");
        harness.distributeYield(
            distModule,
            1,
            address(token),
            100
        );
    }

    function test_YieldHandling_getApprovalTarget() public {
        // No module
        address target = harness.getApprovalTarget(IYieldGenerationModule(address(0)), address(token));
        assertEq(target, address(0));

        // Module with support
        genModule.setApprovalTarget(address(0x123));
        target = harness.getApprovalTarget(genModule, address(token));
        assertEq(target, address(0x123));

        // Module without support (revert)
        genModule.setRevertOnTarget(true);
        target = harness.getApprovalTarget(genModule, address(token));
        assertEq(target, address(0));
    }

    // ============ YieldPresetLibrary Tests ============

    function test_YieldPreset_isYieldEnabled() public {
        assertFalse(harness.isYieldEnabled(YieldPreset.OFF));
        assertTrue(harness.isYieldEnabled(YieldPreset.TO_SENDER));
    }

    function test_YieldPreset_deriveDistributionData_OFF() public {
        bytes memory data = harness.deriveDistributionData(YieldPreset.OFF, address(0x1), address(0x2));
        assertEq(data.length, 0);
    }

    function test_YieldPreset_deriveDistributionData_TO_SENDER() public {
        address sender = address(0x1);
        bytes memory data = harness.deriveDistributionData(YieldPreset.TO_SENDER, sender, address(0x2));
        
        (address[] memory recipients, uint256[] memory percentages) = abi.decode(data, (address[], uint256[]));
        assertEq(recipients.length, 1);
        assertEq(recipients[0], sender);
        assertEq(percentages.length, 1);
        assertEq(percentages[0], 10000);
    }

    function test_YieldPreset_deriveDistributionData_InvalidSender() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector, ADDR_GENERIC, address(0)));
        harness.deriveDistributionData(YieldPreset.TO_SENDER, address(0), address(0x2));
    }

    function test_YieldPreset_deriveDistributionData_InvalidPreset() public {
        uint8 invalid = 99;
        // vm.expectRevert(); 
        // Cast happens before call, so we must use low-level call to pass invalid data to harness
        (bool success, ) = address(harness).call(
            abi.encodeWithSelector(
                harness.deriveDistributionData.selector,
                invalid, // Passed as uint8, harness expects enum
                address(0x1),
                address(0x2)
            )
        );
        assertFalse(success, "Should have reverted due to invalid enum");
    }

    function test_YieldPreset_validatePresetParams() public {
        harness.validatePresetParams(YieldPreset.OFF, address(0), address(0));
        harness.validatePresetParams(YieldPreset.TO_SENDER, address(0x1), address(0));
        
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector, ADDR_GENERIC, address(0)));
        harness.validatePresetParams(YieldPreset.TO_SENDER, address(0), address(0));
    }

    // ============ YieldDistributionLibrary Tests ============

    function test_YieldDistribution_validate_Success() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 10000;
        harness.validateYieldDistribution(recipients, percentages);
    }

    function test_YieldDistribution_validate_Empty() public {
        address[] memory recipients = new address[](0);
        uint256[] memory percentages = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(InvalidAmount.selector, AMOUNT_EMPTY));
        harness.validateYieldDistribution(recipients, percentages);
    }

    function test_YieldDistribution_validate_Mismatch() public {
        address[] memory recipients = new address[](1);
        uint256[] memory percentages = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(ArrayLengthMismatch.selector, 1, 0));
        harness.validateYieldDistribution(recipients, percentages);
    }

    function test_YieldDistribution_validate_ZeroAddress() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 10000;
        vm.expectRevert(abi.encodeWithSelector(InvalidAddress.selector, ADDR_RECIPIENT, address(0)));
        harness.validateYieldDistribution(recipients, percentages);
    }

    function test_YieldDistribution_validate_ZeroPercent() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(InvalidAmount.selector, AMOUNT_GENERIC));
        harness.validateYieldDistribution(recipients, percentages);
    }

    function test_YieldDistribution_validate_BadSum() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 9999;
        vm.expectRevert(abi.encodeWithSelector(InvalidAmount.selector, AMOUNT_GENERIC));
        harness.validateYieldDistribution(recipients, percentages);
    }

    function test_YieldDistribution_decode() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 10000;
        bytes memory data = abi.encode(recipients, percentages);
        
        (address[] memory r, uint256[] memory p) = harness.decodeYieldDistribution(data);
        assertEq(r[0], recipients[0]);
        assertEq(p[0], percentages[0]);
    }

    function test_YieldDistribution_fallback() public {
        token.mint(address(harness), 100); // Give tokens to harness
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x1);
        uint256[] memory percentages = new uint256[](1);
        percentages[0] = 5000; // 50%
        address feeAddress = address(0x2);

        // Distribute 100 tokens: 50 to recipient, 50 to fee
        uint256 distributed = harness.distributeYieldFallback(
            address(token),
            100,
            recipients,
            percentages,
            feeAddress
        );
        
        assertEq(distributed, 50);
        assertEq(token.balanceOf(address(0x1)), 50);
        assertEq(token.balanceOf(address(0x2)), 50);
    }
}

// ============ Mocks ============

contract MockGenModule is IYieldGenerationModule {
    bool public success;
    uint256 public actual;
    uint256 public yield;
    address public approvalTarget;
    bool public revertOnTarget;

    function setWithdrawResult(bool _s, uint256 _a, uint256 _y) external {
        success = _s;
        actual = _a;
        yield = _y;
    }

    function setApprovalTarget(address _t) external {
        approvalTarget = _t;
    }

    function setRevertOnTarget(bool _r) external {
        revertOnTarget = _r;
    }

    function withdrawWithYield(uint256, address, uint256) external view returns (bool, uint256, uint256) {
        return (success, actual, yield);
    }

    function getApprovalTarget(address) external view returns (address) {
        if (revertOnTarget) revert("Not supported");
        return approvalTarget;
    }

    function depositForYield(uint256, address, uint256) external pure returns (bool, uint256) { return (true, 0); }
    function calculateYield(uint256, address) external pure returns (uint256) { return 0; }
    function isTokenSupported(address) external pure returns (bool) { return true; }
    function moduleName() external pure returns (string memory) { return "MockGen"; }
    function moduleVersion() external pure returns (string memory) { return "1.0"; }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
}

contract MockDistModule is IYieldDistributionModule {
    bool public success;

    function setDistributeResult(bool _s) external {
        success = _s;
    }

    function distributeYield(uint256, address, uint256, bytes calldata) external view returns (bool, uint256) {
        return (success, 0);
    }

    function moduleName() external pure returns (string memory) { return "MockDist"; }
    function moduleVersion() external pure returns (string memory) { return "1.0"; }
    function supportsInterface(bytes4) external pure returns (bool) { return true; }
}
