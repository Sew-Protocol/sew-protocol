#!/usr/bin/env bash
set -euo pipefail

# Live "contract insufficient balance" behavior checks on Base Sepolia.
#
# Required:
#   TEST_BUYER_PRIVATE_KEY=0x...
#   TEST_SELLER_PRIVATE_KEY=0x...
#
# Optional:
#   TEST_FEE_WITHDRAWER_PRIVATE_KEY=0x...   # defaults to buyer key if unset
#   TEST_ESCROW_TOKEN=0x...                 # token to probe for withdrawFees()
#   TEST_SEND_REVERT_TXS=1                  # actually send reverting txs (costs gas)
#   TEST_POLL_SECONDS=2

pnpm hardhat run --network baseSepolia scripts/testnet/phase1-contract-insufficient-balance.ts

