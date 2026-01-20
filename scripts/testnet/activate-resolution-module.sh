#!/usr/bin/env bash
set -euo pipefail

# Activate queued EscrowVault.disputeResolutionModule via EscrowAdminContract slow lane.
#
# Required env vars:
#   DEPLOYER_PRIVATE_KEY=0x...   # must have EscrowAdminContract.ROLE_TIMELOCK
#
# Usage:
#   DEPLOYER_PRIVATE_KEY=... ./scripts/testnet/activate-resolution-module.sh

pnpm hardhat run --network baseSepolia scripts/testnet/activate-resolution-module.ts

