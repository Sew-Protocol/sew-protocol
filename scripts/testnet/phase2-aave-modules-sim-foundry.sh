#!/usr/bin/env bash
set -euo pipefail

# Phase 2: Aave module simulations (Foundry).
#
# Usage:
#   ./scripts/testnet/phase2-aave-modules-sim-foundry.sh

forge test --match-path "test/foundry/testnet/Phase2AaveYieldGenerationModule.t.sol" -vvv

