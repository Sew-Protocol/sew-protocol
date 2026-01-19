#!/usr/bin/env bash
set -euo pipefail

# Deploy DefaultResolutionModule and queue it as EscrowVault.disputeResolutionModule via EscrowAdminContract slow lane.
#
# Required env vars:
#   DEPLOYER_PRIVATE_KEY=0x...   # must have EscrowAdminContract.ROLE_TIMELOCK
#   INITIAL_RESOLVER=0x...       # initial resolver address for the module
#
# Usage:
#   DEPLOYER_PRIVATE_KEY=... INITIAL_RESOLVER=... ./scripts/testnet/deploy-default-resolution-module-and-queue.sh

pnpm hardhat run --network baseSepolia scripts/testnet/deploy-default-resolution-module-and-queue.ts

