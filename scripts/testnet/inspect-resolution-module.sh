#!/usr/bin/env bash
set -euo pipefail

# Inspect current resolution module wiring on Base Sepolia.
#
# Usage:
#   ./scripts/testnet/inspect-resolution-module.sh

pnpm hardhat run --network baseSepolia scripts/testnet/inspect-resolution-module.ts

