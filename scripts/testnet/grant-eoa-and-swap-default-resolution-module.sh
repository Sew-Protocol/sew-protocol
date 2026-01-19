#!/usr/bin/env bash
set -euo pipefail

# Grant an EOA EscrowVault.ROLE_ADMIN_CONTRACT and swap in DefaultResolutionModule immediately (testnet convenience).
#
# Required env vars:
#   ADMIN_PRIVATE_KEY=0x...     # must be able to grant EscrowVault roles (DEFAULT_ADMIN_ROLE or role admin)
#   EOA_PRIVATE_KEY=0x...       # the EOA that will call EscrowVault.setResolutionModule()
#   INITIAL_RESOLVER=0x...      # resolver address used by DefaultResolutionModule
#
# Usage:
#   ADMIN_PRIVATE_KEY=... EOA_PRIVATE_KEY=... INITIAL_RESOLVER=... ./scripts/testnet/grant-eoa-and-swap-default-resolution-module.sh

pnpm hardhat run --network baseSepolia scripts/testnet/grant-eoa-and-swap-default-resolution-module.ts

