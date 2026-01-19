#!/usr/bin/env bash
set -euo pipefail

# Phase 1 testnet journeys: cancel + dispute (cancel/release) on Base Sepolia.
#
# Required env vars:
#   TEST_BUYER_PRIVATE_KEY=0x...
#   TEST_SELLER_PRIVATE_KEY=0x...
#   TEST_RESOLVER_PRIVATE_KEY=0x...
#
# Optional:
#   TEST_ESCROW_TOKEN=0x...            # defaults to SewToken if unset
#   TEST_ESCROW_AMOUNT=100             # human units (uses token decimals)
#   TEST_WAIT_FOR_APPEAL_WINDOW=1      # WARNING: Default resolution module implies ~2 days wait
#   TEST_POLL_SECONDS=30               # poll cadence while waiting

pnpm hardhat run --network baseSepolia scripts/testnet/phase1-usdc-journeys.ts

