#!/usr/bin/env bash
set -euo pipefail

# Deploy DefaultResolutionModule and set it immediately on EscrowVault (bypasses slow lane).
#
# Required env vars:
#   DEPLOYER_PRIVATE_KEY=0x...   # must be able to call EscrowVault.setResolutionModule (or grant itself ROLE_ADMIN_CONTRACT)
#   INITIAL_RESOLVER=0x...       # initial resolver address for the module
#
# Usage:
#   DEPLOYER_PRIVATE_KEY=... INITIAL_RESOLVER=... ./scripts/testnet/deploy-default-resolution-module-and-set-immediate.sh

pnpm hardhat run --network baseSepolia scripts/testnet/deploy-default-resolution-module-and-set-immediate.ts

