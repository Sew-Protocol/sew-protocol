// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import './EscrowDisputes.sol';

// Placeholder responsibility boundary. Appeal behavior will be moved here from
// the composition root in a later slice; no behavior or storage is added yet.
abstract contract EscrowAppeals is EscrowDisputes {}
