// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import "forge-std/Test.sol";
import "../../../contracts/libraries/BalanceUpdateLibrary.sol";
import "../../../contracts/libraries/FeeRecordingLibrary.sol";
import "../../../contracts/libraries/FeeWithdrawalLibrary.sol";
import "../../../contracts/libraries/RecoveryLibrary.sol";
import "../../../contracts/libraries/SettingsValidationLibrary.sol";
import "../../../contracts/libraries/YieldPresetLibrary.sol";
import "../../../contracts/mocks/ERC20Mock.sol";
import "../../../contracts/types/EscrowTypes.sol";
import "../../../contracts/types/YieldPresets.sol";

contract LibraryHarness {

    mapping(address => uint256) public balances;

    mapping(address => uint256) public fees;



    function updateBalance(address token, uint256 amount, bool add) external {

        BalanceUpdateLibrary.updateBalance(balances, token, amount, add);

    }



    function recordFee(address token, uint256 amount) external {

        FeeRecordingLibrary.recordFee(fees, token, amount);

    }



    function withdrawFees(address token, address feeRecipient) external returns (uint256) {

        return FeeWithdrawalLibrary.withdrawFees(fees, token, feeRecipient);

    }



    function recoverNativeETH(address recipient, uint256 amount, uint256 contractBalance) external returns (uint256) {

        return RecoveryLibrary.recoverNativeETH(recipient, amount, contractBalance);

    }



    function recoverERC20(address token, address recipient, uint256 amount, uint256 contractBalance) external returns (uint256) {

        return RecoveryLibrary.recoverERC20(token, recipient, amount, contractBalance);

    }



    // SettingsValidation wrapper

    function validateAutoTime(uint256 autoTime, uint256 currentTime) external pure {

        SettingsValidationLibrary.validateAutoTime(autoTime, currentTime);

    }

    function validateEscrowAmount(uint256 amount) external pure {

        SettingsValidationLibrary.validateEscrowAmount(amount);

    }

        function validateRecipient(address recipient, address sender) external pure {

            SettingsValidationLibrary.validateRecipient(recipient, sender, address(0));

    }

    function validateAutoCancel(uint256 t) external view {

        SettingsValidationLibrary.validateAutoCancel(t);

    }

    function validateAutoRelease(uint256 t) external view {

        SettingsValidationLibrary.validateAutoRelease(t);

    }

    function validateMaxAttachments(uint256 n) external pure {

        SettingsValidationLibrary.validateMaxAttachments(n);

    }

    function validateFeeBps(uint256 bps) external pure {

        SettingsValidationLibrary.validateFeeBps(bps);

    }

    function validateResolutionDelay(uint256 d) external pure {

        SettingsValidationLibrary.validateResolutionDelay(d);

    }




    // YieldPreset wrapper

    function validatePresetParams(YieldPreset preset, address sender, address recipient) external pure {

        YieldPresetLibrary.validatePresetParams(preset, sender, recipient);

    }



}



contract LibraryCoverageTest is Test {



    LibraryHarness public harness;



    ERC20Mock public token;



    address public user1 = address(0x1);



    address public feeAddress = address(0xFEE);







    function setUp() public {

        harness = new LibraryHarness();

        token = new ERC20Mock("Test", "TEST", address(this), 1000e18);

    }



    // ============ BalanceUpdateLibrary Tests ============



    function test_BalanceUpdate_Success() public {

        harness.updateBalance(address(token), 100, true);

        assertEq(harness.balances(address(token)), 100);

        

        harness.updateBalance(address(token), 40, false);

        assertEq(harness.balances(address(token)), 60);

    }



    function test_BalanceUpdate_ZeroAddress_Revert() public {

        vm.expectRevert();

        harness.updateBalance(address(0), 100, true);

    }



    function test_BalanceUpdate_Underflow_Revert() public {

        harness.updateBalance(address(token), 50, true);

        vm.expectRevert();

        harness.updateBalance(address(token), 100, false);

    }



    // ============ FeeRecordingLibrary Tests ============



    function test_FeeRecording_Success() public {

        harness.recordFee(address(token), 100);

        assertEq(harness.fees(address(token)), 100);

    }



    function test_FeeRecording_Overflow_Revert() public {

        harness.recordFee(address(token), type(uint256).max - 10);

        vm.expectRevert();

        harness.recordFee(address(token), 20);

    }



    // ============ FeeWithdrawalLibrary Tests ============



    function test_FeeWithdrawal_Success() public {

        harness.recordFee(address(token), 100);

        token.mint(address(harness), 100);

        

        uint256 withdrawn = harness.withdrawFees(address(token), user1);

        assertEq(withdrawn, 100);

        assertEq(token.balanceOf(user1), 100);

        assertEq(harness.fees(address(token)), 0);

    }



    function test_FeeWithdrawal_NoFees_Revert() public {

        vm.expectRevert();

        harness.withdrawFees(address(token), user1);

    }



    function test_FeeWithdrawal_InsufficientBalance_Revert() public {

        harness.recordFee(address(token), 100);

        // Don't mint tokens to harness

        vm.expectRevert();

        harness.withdrawFees(address(token), user1);

    }



    // ============ RecoveryLibrary Tests ============



    function test_recoverNativeETH_Success() public {

        vm.deal(address(harness), 1 ether);

        uint256 recovered = harness.recoverNativeETH(user1, 0.5 ether, 1 ether);

        assertEq(recovered, 0.5 ether);

        assertEq(user1.balance, 0.5 ether);

    }



    function test_recoverNativeETH_All_Success() public {

        vm.deal(address(harness), 1 ether);

        uint256 recovered = harness.recoverNativeETH(user1, 0, 1 ether);

        assertEq(recovered, 1 ether);

        assertEq(user1.balance, 1 ether);

    }



    function test_recoverNativeETH_InvalidAmount_Revert() public {

        vm.expectRevert();

        harness.recoverNativeETH(user1, 0, 0);

        

        vm.expectRevert();

        harness.recoverNativeETH(user1, 2 ether, 1 ether);

    }



    function test_recoverERC20_Success() public {

        token.mint(address(harness), 100);

        uint256 recovered = harness.recoverERC20(address(token), user1, 100, 100);

        assertEq(recovered, 100);

        assertEq(token.balanceOf(user1), 100);

    }



    // ============ SettingsValidationLibrary Tests ============



    function test_SettingsValidation_validateAutoTime() public {

        harness.validateAutoTime(0, block.timestamp);

        harness.validateAutoTime(block.timestamp + 1, block.timestamp);

        

        vm.expectRevert();

        harness.validateAutoTime(block.timestamp, block.timestamp);

        

        vm.expectRevert();

        harness.validateAutoTime(block.timestamp + 11 * 365 days, block.timestamp);

    }



    function test_SettingsValidation_validateEscrowAmount() public {

        harness.validateEscrowAmount(1000);

        vm.expectRevert();

        harness.validateEscrowAmount(999);

    }



    function test_SettingsValidation_validateRecipient() public {

        harness.validateRecipient(address(0x1), address(0x2));

        vm.expectRevert();

        harness.validateRecipient(address(0), address(0x2));

        vm.expectRevert();

        harness.validateRecipient(address(0x1), address(0x1));

    }



        function test_SettingsValidation_validateYieldOptIn() public {



            assertFalse(SettingsValidationLibrary.validateYieldOptIn(1000e6, false));



            assertTrue(SettingsValidationLibrary.validateYieldOptIn(1000e6, true));



            assertTrue(SettingsValidationLibrary.validateYieldOptIn(999e6, true));



        }



    



        function test_SettingsValidation_validateAutoCancel() public {



            harness.validateAutoCancel(0);



            harness.validateAutoCancel(1);



            



            vm.expectRevert();



            harness.validateAutoCancel(31 days);



        }



    



        function test_SettingsValidation_validateAutoRelease() public {



            harness.validateAutoRelease(0);



            harness.validateAutoRelease(1);



            



            vm.expectRevert();



            harness.validateAutoRelease(31 days);



        }



    function test_SettingsValidation_validateMaxAttachments() public {

        harness.validateMaxAttachments(20);

        vm.expectRevert();

        harness.validateMaxAttachments(21);

    }



    function test_SettingsValidation_validateFeeBps() public {

        harness.validateFeeBps(200);

        vm.expectRevert();

        harness.validateFeeBps(201);

    }



    function test_SettingsValidation_validateResolutionDelay() public {

        harness.validateResolutionDelay(48 hours);

        harness.validateResolutionDelay(30 days);

        

        vm.expectRevert();

        harness.validateResolutionDelay(47 hours);

        vm.expectRevert();

        harness.validateResolutionDelay(31 days);

    }






    // ============ YieldPresetLibrary Tests ============



    function test_YieldPreset_deriveDistributionData_OFF() public {

        bytes memory data = YieldPresetLibrary.deriveDistributionData(YieldPreset.OFF, address(0), address(0));

        assertEq(data.length, 0);

    }



    function test_YieldPreset_deriveDistributionData_TO_SENDER() public {

        bytes memory data = YieldPresetLibrary.deriveDistributionData(YieldPreset.TO_SENDER, user1, address(0));

        (address[] memory r, uint256[] memory p) = abi.decode(data, (address[], uint256[]));

        assertEq(r.length, 1);

        assertEq(r[0], user1);

        assertEq(p[0], 10000);

    }



    function test_YieldPreset_isYieldEnabled() public {

        assertFalse(YieldPresetLibrary.isYieldEnabled(YieldPreset.OFF));

        assertTrue(YieldPresetLibrary.isYieldEnabled(YieldPreset.TO_SENDER));

    }



    function test_YieldPreset_validatePresetParams() public {

        YieldPresetLibrary.validatePresetParams(YieldPreset.OFF, address(0), address(0));

        YieldPresetLibrary.validatePresetParams(YieldPreset.TO_SENDER, user1, address(0));

        vm.expectRevert();

        harness.validatePresetParams(YieldPreset.TO_SENDER, address(0), address(0));

    }



}
