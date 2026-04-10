// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @dev Minimal deployed contract used as a per-escrow customResolver in
///      HalmosEscrowProperties property tests.  CreateOps requires customResolver
///      to be a contract (code.length > 0); this satisfies that guard without
///      implementing any resolver interface.
contract MockCustomResolver {}
