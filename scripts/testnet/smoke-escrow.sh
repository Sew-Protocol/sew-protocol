#!/usr/bin/env bash
set -euo pipefail

# Base Sepolia smoke tests for EscrowVault.
#
# Usage:
#   ./scripts/testnet/smoke-escrow.sh
#
# Optional env vars:
#   BUYER_PRIVATE_KEY=0x...
#   SELLER_PRIVATE_KEY=0x...
#   ESCROW_TOKEN=0x...          # defaults to SewToken deployment
#   ESCROW_AMOUNT=1             # human units (uses token decimals)
#
# Notes:
# - This script runs the TypeScript Hardhat script. Do NOT execute the .ts directly.

pnpm hardhat run --network baseSepolia scripts/testnet/smoke-escrow.ts

