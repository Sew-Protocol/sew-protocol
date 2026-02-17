// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

enum DeltaConstraint {
    NO_CHANGE,
    INCREASE_EXACT,
    INCREASE_MAX,
    INCREASE_MIN,
    DECREASE_EXACT,
    DECREASE_MAX,
    DECREASE_MIN
}

struct CodeInvariant {
    bytes32 beforeCodeHash;
    bytes32 afterCodeHash;
}

struct ValuePerPosition {
    uint256 beforeValue;
    uint256 afterValue;
    uint256 delta;
}

struct AddressInvariant {
    address beforeOwner;
    address afterOwner;
}

struct AccountArrayInvariant {
    address[] accountArray;
}

error LengthMismatch();
error UnsupportedInvariant();
error InvalidDeltaConstraint(DeltaConstraint deltaConstraint);
error ArrayTooLarge(uint256 length, uint256 maxLength);

library InvariantGuardHelper {
    uint256 internal constant MAX_PROTECTED_SLOTS = 0xffff;

    function _emptyArray(uint256 length) internal pure returns (uint256[] memory) {
        return new uint256[](length);
    }

    function _getBytes32ArrayLength(bytes32[] memory bytes32Array) internal pure returns (uint256) {
        return bytes32Array.length;
    }

    function _getUint256ArrayLength(uint256[] memory uint256Array) internal pure returns (uint256) {
        return uint256Array.length;
    }

    function _getAddressArrayLength(address[] memory addressArray) internal pure returns (uint256) {
        return addressArray.length;
    }

    function _revertIfArrayTooLarge(uint256 numPositions) internal pure {
        if (numPositions > MAX_PROTECTED_SLOTS) revert ArrayTooLarge(numPositions, MAX_PROTECTED_SLOTS);
    }

    function _isDeltaViolation(
        uint256 beforeValue,
        uint256 afterValue,
        uint256 expectedDelta,
        DeltaConstraint deltaConstraint
    ) internal pure returns (bool) {
        if (deltaConstraint == DeltaConstraint.NO_CHANGE) {
            return beforeValue != afterValue;
        } else if (deltaConstraint == DeltaConstraint.INCREASE_EXACT) {
            if (afterValue < beforeValue) return true;
            unchecked {
                return afterValue - beforeValue != expectedDelta;
            }
        } else if (deltaConstraint == DeltaConstraint.INCREASE_MAX) {
            if (afterValue < beforeValue) return true;
            unchecked {
                return afterValue - beforeValue > expectedDelta;
            }
        } else if (deltaConstraint == DeltaConstraint.INCREASE_MIN) {
            if (afterValue < beforeValue) return true;
            unchecked {
                return afterValue - beforeValue < expectedDelta;
            }
        } else if (deltaConstraint == DeltaConstraint.DECREASE_EXACT) {
            if (beforeValue < afterValue) return true;
            unchecked {
                return beforeValue - afterValue != expectedDelta;
            }
        } else if (deltaConstraint == DeltaConstraint.DECREASE_MAX) {
            if (beforeValue < afterValue) return true;
            unchecked {
                return beforeValue - afterValue > expectedDelta;
            }
        } else if (deltaConstraint == DeltaConstraint.DECREASE_MIN) {
            if (beforeValue < afterValue) return true;
            unchecked {
                return beforeValue - afterValue < expectedDelta;
            }
        } else {
            revert InvalidDeltaConstraint(deltaConstraint);
        }
    }

    function _validateDeltaArray(
        uint256[] memory beforeValueArray,
        uint256[] memory afterValueArray,
        uint256[] memory expectedDeltaArray,
        DeltaConstraint deltaConstraint
    ) internal pure returns (uint256, ValuePerPosition[] memory) {
        uint256 length = _getUint256ArrayLength(expectedDeltaArray);
        _revertIfArrayTooLarge(length);
        if (_getUint256ArrayLength(beforeValueArray) != length || _getUint256ArrayLength(afterValueArray) != length)
            revert LengthMismatch();
        bool valueMismatch;
        uint256 violationCount;
        ValuePerPosition[] memory violations = new ValuePerPosition[](length);
        for (uint256 i = 0; i < length; ) {
            valueMismatch = _isDeltaViolation(beforeValueArray[i], afterValueArray[i], expectedDeltaArray[i], deltaConstraint);
            assembly {
                violationCount := add(violationCount, valueMismatch)
            }
            violations[i] = ValuePerPosition(beforeValueArray[i], afterValueArray[i], expectedDeltaArray[i]);
            unchecked {
                ++i;
            }
        }
        return (violationCount, violations);
    }

    function _validateAddressArray(
        address[] memory beforeOwnerArray,
        address[] memory afterOwnerArray
    ) internal pure returns (uint256, AddressInvariant[] memory) {
        uint256 length = _getAddressArrayLength(afterOwnerArray);
        _revertIfArrayTooLarge(length);
        bool valueMismatch;
        uint256 violationCount;
        AddressInvariant[] memory violations = new AddressInvariant[](length);
        for (uint256 i = 0; i < length; ) {
            valueMismatch = beforeOwnerArray[i] != afterOwnerArray[i];
            assembly {
                violationCount := add(violationCount, valueMismatch)
            }
            violations[i] = AddressInvariant(beforeOwnerArray[i], afterOwnerArray[i]);
            unchecked {
                ++i;
            }
        }
        return (violationCount, violations);
    }
}
