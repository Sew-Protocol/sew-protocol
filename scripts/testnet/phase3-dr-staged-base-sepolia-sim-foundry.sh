#!/usr/bin/env bash
set -euo pipefail

# Phase 3: Decentralized Dispute Resolution staged simulations (DR1 -> DR2 -> DR3) on a Foundry fork.
#
# Required env vars:
#   RPC_BASE_SEPOLIA=https://...
# Optional:
#   FORK_BLOCK_NUMBER=12345678   # 0 or unset = latest
#
# Usage:
#   RPC_BASE_SEPOLIA=... ./scripts/testnet/phase3-dr-staged-base-sepolia-sim-foundry.sh

forge test --match-path "test/foundry/testnet/Phase3DRStagedBaseSepoliaFork.t.sol" -vvv

