#!/usr/bin/env bash
set -euo pipefail

# Base Sepolia stress test: many escrows with delayed release.
#
# Usage:
#   ./scripts/testnet/stress-release-after-delay.sh
#
# Required env vars:
#   TEST_BUYER_PRIVATE_KEY=0x...       # must hold token + Base Sepolia ETH for gas (buyer pays gas + funds escrows)
#
# Optional env vars:
#   TEST_SELLER_PRIVATE_KEY=0x...      # if provided, used to sign pull-withdraws when needed
#   TEST_SELLER_ADDRESS=0x...          # recipient address to validate delivery
#   TEST_ESCROW_TOKEN=0x...            # defaults to SewToken deployment
#   TEST_ESCROW_AMOUNT=1               # human units (uses token decimals)
#   TEST_NUM_TRANSFERS=25
#   TEST_DELAY_SECONDS=15

pnpm hardhat run --network baseSepolia scripts/testnet/stress-release-after-delay.ts

