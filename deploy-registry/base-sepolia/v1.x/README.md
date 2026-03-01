# Base Sepolia v1.x Deployments

## Overview
Phase 4 Yield Testing - Base Sepolia Testnet (Chain ID: 84532)

## Files
- `2026-02-19.json` - Canonical deployment record
- `2026-02-19.report.json` - Optional: contract sizes, interface IDs, code hashes

## Deployment Information
- **Epoch**: v1.x
- **Date**: 2026-02-19
- **Network**: Base Sepolia Testnet
- **Compiler**: Solc 0.8.20, optimizerRuns=10, viaIR=true

## Setup Instructions
1. Copy `config/env/base-sepolia.env.example` to `.env.base-sepolia.local`
2. Fill in required secrets (DEPLOYER_PRIVATE_KEY, RPC_URL, etc.)
3. Run deployment with `pnpm deploy --network baseSepolia --profile v1x`

## Verification
All contracts verified on BaseScan. See `2026-02-19.json` for verification links.

## Related Configuration
- **Deployment params**: `config/deployments/base-sepolia.v1x.json`
- **Environment template**: `config/env/base-sepolia.env.example`
