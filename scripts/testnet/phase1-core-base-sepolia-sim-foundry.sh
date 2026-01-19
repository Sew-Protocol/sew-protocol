#!/usr/bin/env bash
set -euo pipefail

# Phase 1: Core module simulation journeys on a Foundry fork (Base Sepolia).
#
# Required env vars:
#   RPC_BASE_SEPOLIA=https://...
# Optional:
#   FORK_BLOCK_NUMBER=12345678   # 0 or unset = latest
#
# Usage:
#   RPC_BASE_SEPOLIA=... ./scripts/testnet/phase1-core-base-sepolia-sim-foundry.sh

forge test --match-path "test/foundry/testnet/Phase1CoreJourneysBaseSepoliaFork.t.sol" -vvv

