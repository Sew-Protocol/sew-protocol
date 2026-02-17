// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;
import "./InvariantGuardHelper.sol";

error InvariantViolationCode(CodeInvariant codeInvariant);
error InvariantViolationNonce(ValuePerPosition noncePerPosition);
error InvariantViolationBalance(ValuePerPosition balancePerPosition);
error InvariantViolationStorage(ValuePerPosition[] storagePerPosition);
error InvariantViolationTransientStorage(ValuePerPosition[] transientStoragePerPosition);

abstract contract InvariantGuardInternal {
    using InvariantGuardHelper for *;

    modifier invariantCode() {
        bytes32 beforeCodeHash = _getCodeHash();
        _;
        bytes32 afterCodeHash = _getCodeHash();
        _processInvariantCode(beforeCodeHash, afterCodeHash);
    }

    modifier invariantNonce() {
        revert UnsupportedInvariant();
        _;
    }

    modifier assertNonceEquals(uint256 expected) {
        revert UnsupportedInvariant();
        _;
    }

    modifier exactIncreaseNonce(uint256 exactIncrease) {
        revert UnsupportedInvariant();
        _;
    }

    modifier maxIncreaseNonce(uint256 maxIncrease) {
        revert UnsupportedInvariant();
        _;
    }

    modifier minIncreaseNonce(uint256 minIncrease) {
        revert UnsupportedInvariant();
        _;
    }

    modifier invariantBalance() {
        uint256 beforeBalance = _getBalance();
        _;
        uint256 afterBalance = _getBalance();
        _processConstantBalance(beforeBalance, afterBalance);
    }

    modifier assertBalanceEquals(uint256 expected) {
        _;
        uint256 actualBalance = _getBalance();
        _processConstantBalance(expected, actualBalance);
    }

    modifier exactIncreaseBalance(uint256 exactIncrease) {
        uint256 beforeBalance = _getBalance();
        _;
        uint256 afterBalance = _getBalance();
        _processExactIncreaseBalance(beforeBalance, afterBalance, exactIncrease);
    }

    modifier maxIncreaseBalance(uint256 maxIncrease) {
        uint256 beforeBalance = _getBalance();
        _;
        uint256 afterBalance = _getBalance();
        _processMaxIncreaseBalance(beforeBalance, afterBalance, maxIncrease);
    }

    modifier minIncreaseBalance(uint256 minIncrease) {
        uint256 beforeBalance = _getBalance();
        _;
        uint256 afterBalance = _getBalance();
        _processMinIncreaseBalance(beforeBalance, afterBalance, minIncrease);
    }

    modifier exactDecreaseBalance(uint256 exactDecrease) {
        uint256 beforeBalance = _getBalance();
        _;
        uint256 afterBalance = _getBalance();
        _processExactDecreaseBalance(beforeBalance, afterBalance, exactDecrease);
    }

    modifier maxDecreaseBalance(uint256 maxDecrease) {
        uint256 beforeBalance = _getBalance();
        _;
        uint256 afterBalance = _getBalance();
        _processMaxDecreaseBalance(beforeBalance, afterBalance, maxDecrease);
    }

    modifier minDecreaseBalance(uint256 minDecrease) {
        uint256 beforeBalance = _getBalance();
        _;
        uint256 afterBalance = _getBalance();
        _processMinDecreaseBalance(beforeBalance, afterBalance, minDecrease);
    }

    modifier invariantStorage(bytes32[] memory positions) {
        uint256[] memory beforeValueArray = _getStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getStorageArray(positions);
        _processConstantStorage(beforeValueArray, afterValueArray);
    }

    modifier assertStorageEquals(bytes32[] memory positions, uint256[] memory expectedArray) {
        _;
        uint256[] memory actualStorageArray = _getStorageArray(positions);
        _processConstantStorage(expectedArray, actualStorageArray);
    }

    modifier exactIncreaseStorage(bytes32[] memory positions, uint256[] memory exactIncreaseArray) {
        uint256[] memory beforeValueArray = _getStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getStorageArray(positions);
        _processExactIncreaseStorage(beforeValueArray, afterValueArray, exactIncreaseArray);
    }

    modifier maxIncreaseStorage(bytes32[] memory positions, uint256[] memory maxIncreaseArray) {
        uint256[] memory beforeValueArray = _getStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getStorageArray(positions);
        _processMaxIncreaseStorage(beforeValueArray, afterValueArray, maxIncreaseArray);
    }

    modifier minIncreaseStorage(bytes32[] memory positions, uint256[] memory minIncreaseArray) {
        uint256[] memory beforeValueArray = _getStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getStorageArray(positions);
        _processMinIncreaseStorage(beforeValueArray, afterValueArray, minIncreaseArray);
    }

    modifier exactDecreaseStorage(bytes32[] memory positions, uint256[] memory exactDecreaseArray) {
        uint256[] memory beforeValueArray = _getStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getStorageArray(positions);
        _processExactDecreaseStorage(beforeValueArray, afterValueArray, exactDecreaseArray);
    }

    modifier maxDecreaseStorage(bytes32[] memory positions, uint256[] memory maxDecreaseArray) {
        uint256[] memory beforeValueArray = _getStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getStorageArray(positions);
        _processMaxDecreaseStorage(beforeValueArray, afterValueArray, maxDecreaseArray);
    }

    modifier minDecreaseStorage(bytes32[] memory positions, uint256[] memory minDecreaseArray) {
        uint256[] memory beforeValueArray = _getStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getStorageArray(positions);
        _processMinDecreaseStorage(beforeValueArray, afterValueArray, minDecreaseArray);
    }

    modifier invariantTransientStorage(bytes32[] memory positions) {
        uint256[] memory beforeValueArray = _getTransientStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getTransientStorageArray(positions);
        _processConstantTransientStorage(beforeValueArray, afterValueArray);
    }

    modifier assertTransientStorageEquals(bytes32[] memory positions, uint256[] memory expectedArray) {
        _;
        uint256[] memory actualStorageArray = _getTransientStorageArray(positions);
        _processConstantTransientStorage(expectedArray, actualStorageArray);
    }

    modifier exactIncreaseTransientStorage(bytes32[] memory positions, uint256[] memory exactIncreaseArray) {
        uint256[] memory beforeValueArray = _getTransientStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getTransientStorageArray(positions);
        _processExactIncreaseTransientStorage(beforeValueArray, afterValueArray, exactIncreaseArray);
    }

    modifier maxIncreaseTransientStorage(bytes32[] memory positions, uint256[] memory maxIncreaseArray) {
        uint256[] memory beforeValueArray = _getTransientStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getTransientStorageArray(positions);
        _processMaxIncreaseTransientStorage(beforeValueArray, afterValueArray, maxIncreaseArray);
    }

    modifier minIncreaseTransientStorage(bytes32[] memory positions, uint256[] memory minIncreaseArray) {
        uint256[] memory beforeValueArray = _getTransientStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getTransientStorageArray(positions);
        _processMinIncreaseTransientStorage(beforeValueArray, afterValueArray, minIncreaseArray);
    }

    modifier exactDecreaseTransientStorage(bytes32[] memory positions, uint256[] memory exactDecreaseArray) {
        uint256[] memory beforeValueArray = _getTransientStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getTransientStorageArray(positions);
        _processExactDecreaseTransientStorage(beforeValueArray, afterValueArray, exactDecreaseArray);
    }

    modifier maxDecreaseTransientStorage(bytes32[] memory positions, uint256[] memory maxDecreaseArray) {
        uint256[] memory beforeValueArray = _getTransientStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getTransientStorageArray(positions);
        _processMaxDecreaseTransientStorage(beforeValueArray, afterValueArray, maxDecreaseArray);
    }

    modifier minDecreaseTransientStorage(bytes32[] memory positions, uint256[] memory minDecreaseArray) {
        uint256[] memory beforeValueArray = _getTransientStorageArray(positions);
        _;
        uint256[] memory afterValueArray = _getTransientStorageArray(positions);
        _processMinDecreaseTransientStorage(beforeValueArray, afterValueArray, minDecreaseArray);
    }

    function _getCodeHash() private view returns (bytes32) {
        bytes32 codeHash;
        assembly {
            codeHash := extcodehash(address())
        }
        return codeHash;
    }

    function _processInvariantCode(bytes32 beforeCodeHash, bytes32 afterCodeHash) private pure {
        if (beforeCodeHash != afterCodeHash) revert InvariantViolationCode(CodeInvariant(beforeCodeHash, afterCodeHash));
    }

    function _getBalance() private view returns (uint256) {
        return address(this).balance;
    }

    function _processConstantBalance(uint256 beforeBalance, uint256 afterBalance) private pure {
        if (beforeBalance._isDeltaViolation(afterBalance, 0, DeltaConstraint.NO_CHANGE))
            revert InvariantViolationBalance(ValuePerPosition(beforeBalance, afterBalance, 0));
    }

    function _processExactIncreaseBalance(
        uint256 beforeBalance,
        uint256 afterBalance,
        uint256 exactIncrease
    ) private pure {
        if (beforeBalance._isDeltaViolation(afterBalance, exactIncrease, DeltaConstraint.INCREASE_EXACT))
            revert InvariantViolationBalance(ValuePerPosition(beforeBalance, afterBalance, exactIncrease));
    }

    function _processMaxIncreaseBalance(uint256 beforeBalance, uint256 afterBalance, uint256 maxIncrease) private pure {
        if (beforeBalance._isDeltaViolation(afterBalance, maxIncrease, DeltaConstraint.INCREASE_MAX))
            revert InvariantViolationBalance(ValuePerPosition(beforeBalance, afterBalance, maxIncrease));
    }

    function _processMinIncreaseBalance(uint256 beforeBalance, uint256 afterBalance, uint256 minIncrease) private pure {
        if (beforeBalance._isDeltaViolation(afterBalance, minIncrease, DeltaConstraint.INCREASE_MIN))
            revert InvariantViolationBalance(ValuePerPosition(beforeBalance, afterBalance, minIncrease));
    }

    function _processExactDecreaseBalance(
        uint256 beforeBalance,
        uint256 afterBalance,
        uint256 exactDecrease
    ) private pure {
        if (beforeBalance._isDeltaViolation(afterBalance, exactDecrease, DeltaConstraint.DECREASE_EXACT))
            revert InvariantViolationBalance(ValuePerPosition(beforeBalance, afterBalance, exactDecrease));
    }

    function _processMaxDecreaseBalance(uint256 beforeBalance, uint256 afterBalance, uint256 maxDecrease) private pure {
        if (beforeBalance._isDeltaViolation(afterBalance, maxDecrease, DeltaConstraint.DECREASE_MAX))
            revert InvariantViolationBalance(ValuePerPosition(beforeBalance, afterBalance, maxDecrease));
    }

    function _processMinDecreaseBalance(uint256 beforeBalance, uint256 afterBalance, uint256 minDecrease) private pure {
        if (beforeBalance._isDeltaViolation(afterBalance, minDecrease, DeltaConstraint.DECREASE_MIN))
            revert InvariantViolationBalance(ValuePerPosition(beforeBalance, afterBalance, minDecrease));
    }

    function _getStorageArray(bytes32[] memory positions) private view returns (uint256[] memory) {
        uint256 numPositions = positions._getBytes32ArrayLength();
        numPositions._revertIfArrayTooLarge();
        uint256[] memory valueArray = new uint256[](numPositions);
        for (uint256 i = 0; i < numPositions; ) {
            bytes32 slot = positions[i];
            uint256 slotValue;
            assembly {
                slotValue := sload(slot)
            }
            valueArray[i] = slotValue;
            unchecked {
                ++i;
            }
        }
        return valueArray;
    }

    function _processConstantStorage(uint256[] memory beforeValueArray, uint256[] memory afterValueArray) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            beforeValueArray._getUint256ArrayLength()._emptyArray(),
            DeltaConstraint.NO_CHANGE
        );
        if (violationCount > 0) revert InvariantViolationStorage(violations);
    }

    function _processExactIncreaseStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory exactIncreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            exactIncreaseArray,
            DeltaConstraint.INCREASE_EXACT
        );
        if (violationCount > 0) revert InvariantViolationStorage(violations);
    }

    function _processMaxIncreaseStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory maxIncreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            maxIncreaseArray,
            DeltaConstraint.INCREASE_MAX
        );
        if (violationCount > 0) revert InvariantViolationStorage(violations);
    }

    function _processMinIncreaseStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory minIncreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            minIncreaseArray,
            DeltaConstraint.INCREASE_MIN
        );
        if (violationCount > 0) revert InvariantViolationStorage(violations);
    }

    function _processExactDecreaseStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory exactDecreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            exactDecreaseArray,
            DeltaConstraint.DECREASE_EXACT
        );
        if (violationCount > 0) revert InvariantViolationStorage(violations);
    }

    function _processMaxDecreaseStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory maxDecreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            maxDecreaseArray,
            DeltaConstraint.DECREASE_MAX
        );
        if (violationCount > 0) revert InvariantViolationStorage(violations);
    }

    function _processMinDecreaseStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory minDecreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            minDecreaseArray,
            DeltaConstraint.DECREASE_MIN
        );
        if (violationCount > 0) revert InvariantViolationStorage(violations);
    }

    function _getTransientStorageArray(bytes32[] memory positions) private view returns (uint256[] memory) {
        uint256 numPositions = positions._getBytes32ArrayLength();
        numPositions._revertIfArrayTooLarge();
        uint256[] memory valueArray = new uint256[](numPositions);
        for (uint256 i = 0; i < numPositions; ) {
            bytes32 slot = positions[i];
            uint256 slotValue;
            assembly {
                slotValue := tload(slot)
            }
            valueArray[i] = slotValue;
            unchecked {
                ++i;
            }
        }
        return valueArray;
    }

    function _processConstantTransientStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            beforeValueArray._getUint256ArrayLength()._emptyArray(),
            DeltaConstraint.NO_CHANGE
        );
        if (violationCount > 0) revert InvariantViolationTransientStorage(violations);
    }

    function _processExactIncreaseTransientStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory exactIncreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            exactIncreaseArray,
            DeltaConstraint.INCREASE_EXACT
        );
        if (violationCount > 0) revert InvariantViolationTransientStorage(violations);
    }

    function _processMaxIncreaseTransientStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory maxIncreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            maxIncreaseArray,
            DeltaConstraint.INCREASE_MAX
        );
        if (violationCount > 0) revert InvariantViolationTransientStorage(violations);
    }

    function _processMinIncreaseTransientStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory minIncreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            minIncreaseArray,
            DeltaConstraint.INCREASE_MIN
        );
        if (violationCount > 0) revert InvariantViolationTransientStorage(violations);
    }

    function _processExactDecreaseTransientStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory exactDecreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            exactDecreaseArray,
            DeltaConstraint.DECREASE_EXACT
        );
        if (violationCount > 0) revert InvariantViolationTransientStorage(violations);
    }

    function _processMaxDecreaseTransientStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory maxDecreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            maxDecreaseArray,
            DeltaConstraint.DECREASE_MAX
        );
        if (violationCount > 0) revert InvariantViolationTransientStorage(violations);
    }

    function _processMinDecreaseTransientStorage(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory minDecreaseArray
    ) private pure {
        (uint256 violationCount, ValuePerPosition[] memory violations) = beforeValueArray._validateDeltaArray(
            afterValueArray,
            minDecreaseArray,
            DeltaConstraint.DECREASE_MIN
        );
        if (violationCount > 0) revert InvariantViolationTransientStorage(violations);
    }
}
