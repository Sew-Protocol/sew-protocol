#!/usr/bin/env bash
set -euo pipefail

# Phase 0: Base Sepolia deployment health check on a Foundry fork.
#
# Required env vars:
#   RPC_BASE_SEPOLIA=https://...
# Optional:
#   FORK_BLOCK_NUMBER=12345678   # 0 or unset = latest
#
# Usage:
#   RPC_BASE_SEPOLIA=... ./scripts/testnet/phase0-base-sepolia-health-foundry.sh

forge test --match-path "test/foundry/testnet/Phase0BaseSepoliaFork.t.sol" -vvv

