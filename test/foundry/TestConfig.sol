// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

library TestConfig {
    /// @notice Set to true to run pause-related tests
    /// @dev Set to false to skip pause tests (pause functionality removed for size optimization)
    ///      To re-enable pause tests: set to true AND implement full pause functionality in BaseEscrow
    bool constant RUN_PAUSE_TESTS = false;
}
