#!/usr/bin/env bash
set -euo pipefail

# Phase 0: Base Sepolia deployment health check on a local fork.
#
# Required env vars:
#   RPC_BASE_SEPOLIA=https://...
# Optional:
#   FORK_BLOCK_NUMBER=12345678
#
# Usage:
#   RPC_BASE_SEPOLIA=... ./scripts/testnet/phase0-base-sepolia-health.sh

# NOTE:
# Hardhat-forcing currently fails in some environments due to an upstream Hardhat/EDR limitation.
# Foundry fork runner is used as the canonical Phase 0 entrypoint.

./scripts/testnet/phase0-base-sepolia-health-foundry.sh

