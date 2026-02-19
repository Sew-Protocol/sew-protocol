# Base Sepolia Testnet v0.x - Deprecated Epoch (Jan 20, 2026)

**Status**: ❌ DEPRECATED  
**Replaced By**: `/deployments/baseSepolia/2026-02-18-v1.x/`

---

## What This Is

This directory contains the original Base Sepolia testnet deployment from January 20, 2026. This deployment is **no longer active** and **not supported**.

---

## Why Deprecated

The v1.x epoch (February 18, 2026) represents a significant evolution of the protocol. Changes include:

### Core Changes
- **EscrowVault**: Updated logic and storage layout
- **ModuleRegistry**: Enhanced module management
- **YieldModule**: New Aave integration and yield handling
- **Governance**: Updated TimeController and Governor logic
- **L2AddressRegistry**: New dependency for cross-chain coordination

### Impact
- ❌ ABIs are no longer compatible with v1.x
- ❌ Storage layouts differ (upgrade hazards if attempting to migrate)
- ❌ Event schemas changed (indexers will fail)
- ❌ Role surface modified (security assumptions shifted)
- ❌ Behavioral semantics updated (release/dispute/yield paths altered)

---

## Preserved for Auditability

This archive is kept for:
1. **Historical traceability** — understand what deployed where
2. **Audit narrative** — reference old contract ABIs if needed
3. **On-chain verification** — confirm old Etherscan deployments

---

## What to Do

### If You Have Escrows on v0.x
- **Do not create new escrows** on v0.x contracts
- **New activity** should use v1.x addresses
- **Migrate data** if needed (see ops team for migration tools)

### If You're Integrating
- **Update wallet config** to point to v1.x addresses only
- **Deprecate v0.x** references in documentation
- **Add warnings** if old addresses are still referenced

### If You're Auditing
- Reference this archive for understanding v0.x deployment
- Cross-reference with v1.x to understand what changed
- Use artifact ABIs for on-chain verification

---

## Contact

For questions about this deprecation, see the v1.x release notes:
- Release tag: `testnet/base-sepolia-v1`
- Deployment docs: `/docs/operations/DEPLOYMENT.md`
- Address manifest: `/docs/deployments/base-sepolia-v1-testnet-addresses.md`

---

**Archived**: February 18, 2026  
**Status**: Read-only, not supported  
**Replacement**: Base Sepolia v1.x (Feb 18, 2026)
