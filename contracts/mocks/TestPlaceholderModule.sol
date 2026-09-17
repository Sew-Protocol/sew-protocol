// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

/// @notice Minimal placeholder contract used only as a registered module *address* in
///         module-management / snapshot tests. The ModuleSnapshotRegistry only requires
///         `module.code.length > 0` for queue/activate, so no behavior is needed.
contract TestPlaceholderModule {}
