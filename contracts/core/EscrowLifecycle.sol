// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import './EscrowAppeals.sol';

// Placeholder responsibility boundary. Lifecycle orchestration will be moved
// here from the composition root in a later slice; no behavior or storage added.
abstract contract EscrowLifecycle is EscrowAppeals {}
