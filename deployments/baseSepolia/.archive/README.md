# Base Sepolia Testnet - Archive Index

This directory preserves historical deployments for auditability and reference.

## v0.x (Jan 20, 2026)

**Status**: Deprecated  
**Location**: `/2026-01-20-v0.x/`  
**Replacement**: `/2026-02-18-v1.x/` (coming soon)  

See `2026-01-20-v0.x/DEPRECATION.md` for details on why this epoch is deprecated and what changed.

---

## v1.x (Feb 18, 2026)

**Status**: Active  
**Location**: `/2026-02-18-v1.x/` (once deployment completes)  

The current canonical testnet deployment. See `/docs/deployments/base-sepolia-v1-testnet-addresses.md` for address manifest.

---

## How to Reference Old Deployments

If you need to work with a deprecated epoch:

1. **For ABIs**: Use the JSON artifacts in the epoch directory
2. **For contract verification**: Check Etherscan links recorded in the manifest
3. **For understanding state**: Read the DEPRECATION notice explaining what changed

**Do not deploy new escrows or integrations against deprecated epochs.**
