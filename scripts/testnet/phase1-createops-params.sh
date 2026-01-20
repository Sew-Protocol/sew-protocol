#!/usr/bin/env bash
set -euo pipefail

# Phase 1 CreateOps parameter matrix on Base Sepolia.
#
# Required env vars:
#   TEST_BUYER_PRIVATE_KEY=0x...
#   TEST_SELLER_PRIVATE_KEY=0x...         # used to withdraw if push transfer fails
#   TEST_RESOLVER_PRIVATE_KEY=0x...       # owner of forwarding resolver contract
#
# Optional:
#   TEST_ESCROW_TOKEN=0x...               # defaults to SewToken if unset
#   TEST_ESCROW_AMOUNT=100                # human units (uses token decimals)
#   TEST_CUSTOM_RESOLVER_CONTRACT=0x...   # reuse a deployed forwarding resolver
#   TEST_INCLUDE_DEFAULT_RESOLVER=1       # also test customResolver=0 path (requires configured module)
#   TEST_RUN_NEGATIVE_TXS=1               # send expected-revert txs (costs gas)
#   TEST_POLL_SECONDS=2                   # convergence poll cadence

pnpm hardhat run --network baseSepolia scripts/testnet/phase1-createops-params.ts

