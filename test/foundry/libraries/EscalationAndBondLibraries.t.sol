// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../../contracts/libraries/EscrowEncodingLibrary.sol';
import '../../../contracts/libraries/BondHandlingLibrary.sol';
import '../../../contracts/libraries/DisputeEscalationLibrary.sol';
import '../../../contracts/shared/interfaces/IIncentiveModule.sol';

/// @notice Harness exposing internal library functions for direct testing.
contract EscalationBondHarness {
    function encode(address t, address f, address to, uint256 amt, address rel)
        external pure returns (bytes memory) {
        return EscrowEncodingLibrary.encodeEscrowTransferData(t, f, to, amt, rel);
    }

    function decode(bytes memory d) external pure returns (address, address, address, uint256, address) {
        return EscrowEncodingLibrary.decodeEscrowTransferData(d);
    }

    function processBondWithFee(uint256 amt, address t, uint256 fee, address recipient)
        external pure returns (BondHandlingLibrary.BondProcessingResult memory) {
        return BondHandlingLibrary.processBondWithFee(amt, t, fee, recipient);
    }

    function validateBondMsgValue(address t, uint256 amt, uint256 v)
        external pure returns (bool, uint8) {
        return DisputeEscalationLibrary.validateBondMsgValue(t, amt, v);
    }

    function queryAppealBond(address module, uint256 id, uint8 lvl, bytes memory d)
        external view returns (bool, uint256, address) {
        return DisputeEscalationLibrary.queryAppealBond(module, id, lvl, d);
    }

    function processBondWithFeeCalculation(uint256 amt, address t, address mod, uint256 fee, address recipient)
        external view returns (BondHandlingLibrary.BondProcessingResult memory, IIncentiveModule) {
        return DisputeEscalationLibrary.processBondWithFeeCalculation(amt, t, mod, fee, recipient);
    }
}

/// @notice Minimal mock resolution module exposing getRequiredAppealBond with controllable output.
contract MockEscalationModule {
    uint256 public bondAmount;
    address public bondToken;
    bool public shouldFail;
    bytes public customReturn;

    function setBond(uint256 a, address t) external { bondAmount = a; bondToken = t; }
    function setFail(bool f) external { shouldFail = f; }
    function setCustomReturn(bytes calldata d) external { customReturn = d; }

    function getRequiredAppealBond(uint256, address, uint8, bytes calldata)
        external view returns (uint256, address) {
        if (shouldFail) revert('module failure');
        if (customReturn.length > 0) {
            bytes memory c = customReturn;
            uint256 len = c.length;
            // force a malformed/too-short return via raw return data
            assembly { return(add(c, 32), len) }
        }
        return (bondAmount, bondToken);
    }
}

contract EscrowEncodingTest is Test {
    EscalationBondHarness h;

    function setUp() public { h = new EscalationBondHarness(); }

    function test_encodeDecodeRoundtrip() public {
        (address t, address f, address to, uint256 amt, address rel) =
            (address(0xAA), address(0xBB), address(0xCC), 123456, address(0xDD));
        bytes memory data = h.encode(t, f, to, amt, rel);
        (address dt, address df, address dto, uint256 damt, address drel) = h.decode(data);
        assertEq(dt, t);
        assertEq(df, f);
        assertEq(dto, to);
        assertEq(damt, amt);
        assertEq(drel, rel);
    }
}

contract BondHandlingTest is Test {
    EscalationBondHarness h;
    address recipient = address(0xFEE);
    address token = address(0x1234);

    function setUp() public { h = new EscalationBondHarness(); }

    function test_processBondWithFee_noFee() public {
        BondHandlingLibrary.BondProcessingResult memory r = h.processBondWithFee(1000, token, 0, recipient);
        assertTrue(r.success);
        assertEq(r.bondToRecord, 1000);
        assertEq(r.protocolFeeAmount, 0);
    }

    function test_processBondWithFee_feeZeroRecipient() public {
        // fee > 0 but no recipient -> no fee taken
        BondHandlingLibrary.BondProcessingResult memory r = h.processBondWithFee(1000, token, 100, address(0));
        assertEq(r.protocolFeeAmount, 0);
        assertEq(r.bondToRecord, 1000);
    }

    function test_processBondWithFee_withRecipient() public {
        // 1000 * 100 / 10000 = 10 fee -> bondToRecord = 990
        BondHandlingLibrary.BondProcessingResult memory r = h.processBondWithFee(1000, token, 100, recipient);
        assertEq(r.protocolFeeAmount, 10);
        assertEq(r.bondToRecord, 990);
    }
}

contract DisputeEscalationTest is Test {
    EscalationBondHarness h;
    MockEscalationModule module;

    function setUp() public {
        h = new EscalationBondHarness();
        module = new MockEscalationModule();
    }

    function test_validateBondMsgValue_ethSufficient() public {
        (bool valid, uint8 code) = h.validateBondMsgValue(address(0), 100, 100);
        assertTrue(valid);
        assertEq(code, 0);
    }

    function test_validateBondMsgValue_ethInsufficient() public {
        (bool valid, uint8 code) = h.validateBondMsgValue(address(0), 100, 50);
        assertFalse(valid);
        assertEq(code, 1);
    }

    function test_validateBondMsgValue_erc20NoEth() public {
        (bool valid, uint8 code) = h.validateBondMsgValue(address(0x1), 100, 0);
        assertTrue(valid);
        assertEq(code, 0);
    }

    function test_validateBondMsgValue_erc20UnexpectedEth() public {
        (bool valid, uint8 code) = h.validateBondMsgValue(address(0x1), 100, 1);
        assertFalse(valid);
        assertEq(code, 2);
    }

    function test_queryAppealBond_success() public {
        module.setBond(500, address(0x1234));
        bytes memory data = abi.encode(address(0xAA), address(0xBB), address(0xCC), uint256(100), address(0));
        (bool success, uint256 amount, address bondToken) = h.queryAppealBond(address(module), 1, 0, data);
        assertTrue(success);
        assertEq(amount, 500);
        assertEq(bondToken, address(0x1234));
    }

    function test_queryAppealBond_moduleReverts() public {
        module.setFail(true);
        (bool success, uint256 amount, address bondToken) = h.queryAppealBond(address(module), 1, 0, hex'');
        assertFalse(success);
        assertEq(amount, 0);
        assertEq(bondToken, address(0));
    }

    function test_queryAppealBond_shortReturn() public {
        module.setCustomReturn(abi.encodePacked(hex'1234')); // < 64 bytes
        (bool success, uint256 amount, address bondToken) = h.queryAppealBond(address(module), 1, 0, hex'');
        assertFalse(success);
        assertEq(amount, 0);
        assertEq(bondToken, address(0));
    }

    function test_processBondWithFeeCalculation_zeroAmount() public {
        (BondHandlingLibrary.BondProcessingResult memory r, IIncentiveModule mod) =
            h.processBondWithFeeCalculation(0, address(0x1), address(0x1234), 100, address(0xFEE));
        assertEq(address(mod), address(0));
        assertEq(r.bondToRecord, 0);
    }

    function test_processBondWithFeeCalculation_noModule() public {
        (BondHandlingLibrary.BondProcessingResult memory r, IIncentiveModule mod) =
            h.processBondWithFeeCalculation(1000, address(0x1), address(0), 100, address(0xFEE));
        assertEq(address(mod), address(0));
        assertEq(r.bondToRecord, 0);
    }

    function test_processBondWithFeeCalculation_withModule() public {
        (BondHandlingLibrary.BondProcessingResult memory r, IIncentiveModule mod) =
            h.processBondWithFeeCalculation(1000, address(0x1), address(0x1234), 100, address(0xFEE));
        assertEq(address(mod), address(0x1234));
        assertEq(r.protocolFeeAmount, 10); // 1000 * 100 / 10000
        assertEq(r.bondToRecord, 990);
    }
}
