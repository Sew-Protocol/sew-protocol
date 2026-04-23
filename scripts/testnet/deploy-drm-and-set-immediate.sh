#!/usr/bin/env bash
set -euo pipefail

# Deploy the full DR v3 suite (InsurancePoolVault, StakingModule, SlashingModule,
# BondTokenRegistry, DRMAdminFacet, PaymentCalculationLibraryV1,
# ResolverIncentiveModuleV2, DecentralizedResolutionModule) and immediately
# activate DRM as the resolution module on EscrowVault (bypasses slow lane).
#
# Required env vars:
#   DEPLOYER_PRIVATE_KEY=0x...  # must have DEFAULT_ADMIN_ROLE or ROLE_ADMIN_CONTRACT on EscrowVault
#
# Optional:
#   STABLE_TOKEN_ADDRESS=0x...  # defaults to Base Sepolia USDC
#
# Usage:
#   DEPLOYER_PRIVATE_KEY=0x... ./scripts/testnet/deploy-drm-and-set-immediate.sh

pnpm hardhat run --network baseSepolia scripts/testnet/deploy-drm-and-set-immediate.ts
