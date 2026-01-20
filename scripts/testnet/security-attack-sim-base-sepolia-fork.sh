#!/usr/bin/env bash
set -euo pipefail

# Fork-only "attack simulation" against the deployed Base Sepolia EscrowVault.
# This does NOT broadcast exploit transactions to the live network.
#
# Required:
#   RPC_BASE_SEPOLIA=https://...
# Optional:
#   FORK_BLOCK_NUMBER=36541926
#
# Usage:
#   RPC_BASE_SEPOLIA=... ./scripts/testnet/security-attack-sim-base-sepolia-fork.sh

forge test --match-path "test/foundry/testnet/SecurityAttackSimBaseSepoliaFork.t.sol" -vvv

