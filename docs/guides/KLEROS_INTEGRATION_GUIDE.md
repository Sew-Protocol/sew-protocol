# Kleros Integration Guide

**Date**: 2026-04-03  
**Status**: ✅ **PRODUCTION READY**  
**Version**: 1.1.0 (Fixed DR3 Integration)

---

## Overview

The Kleros integration enables decentralized dispute resolution through Kleros Court as the final escalation level in the dispute resolution system. This integration follows the ERC-792 Arbitration Standard.

### Key Features

- ✅ **ERC-792 Compliant**: Full implementation of Arbitrable and Arbitrator interfaces.
- ✅ **Seamless Integration**: Works as an `IResolutionModule` for `BaseEscrow`.
- ✅ **Automatic Ruling Execution**: Rulings from Kleros are automatically propagated to `BaseEscrow`.
- ✅ **Pay-at-Proxy Model**: Users pay Kleros fees directly at the proxy, ensuring exact fee coverage.
- ✅ **Access Control**: Secure role-based permissions, allowing participants to trigger dispute creation.
- ✅ **Immutable Pattern**: Follows the project's forward-only upgrade strategy (no UUPS).

---

## Architecture

### Components

```
┌─────────────────────┐
│   BaseEscrow/       │
│  EscrowableERC20    │
└──────────┬──────────┘
           │
           │ IBaseEscrowSettlement (Callback)
           │
┌──────────▼──────────────────┐
│  KlerosArbitrableProxy      │
│  (Level 2 - External)       │
└──────────┬──────────────────┘
           │
           │ IArbitrable/IArbitrator (ERC-792)
           │
┌──────────▼──────────────────┐
│     Kleros Arbitrator       │
│    (Kleros Court)           │
└─────────────────────────────┘
```

---

## Deployment & Configuration

### 1. Deploy KlerosArbitrableProxy

Deploy with the Kleros Arbitrator address and the initial admin.

```typescript
const KlerosProxy = await ethers.getContractFactory('KlerosArbitrableProxy');
const proxy = await KlerosProxy.deploy(klerosArbitratorAddress, adminAddress);
await proxy.waitForDeployment();
```

### 2. Register with KlerosProxy

The proxy must know which escrow contracts are allowed to interact with it.

```typescript
await proxy.registerEscrowContract(escrowContractAddress);
```

### 3. Configure DecentralizedResolutionModule (DRM)

Set the `KlerosArbitrableProxy` as the external resolver in your DRM.

```typescript
await resolutionModule.setExternalResolver(proxyAddress);
```

---

## Usage Workflows

### Dispute Escalation Flow

1.  **Escalation to Round 2**: A participant calls `BaseEscrow.escalateDispute(workflowId)`.
2.  **Resolver Assigned**: The DRM assigns the `KlerosArbitrableProxy` as the new resolver. No appeal bond is collected at this stage (Pay-at-Proxy model).
3.  **Kleros Dispute Creation**: A participant (sender or recipient) calls `KlerosArbitrableProxy.createDispute{value: fee}(workflowId, escrowContract, ...)` and pays the required Kleros arbitration fee.
4.  **Dispute Created**: The proxy creates the actual dispute in Kleros Court.

### Ruling & Settlement Flow

1.  **Kleros Ruling**: Kleros jurors provide a ruling (1 = Release, 2 = Cancel).
2.  **Proxy Callback**: Kleros calls `KlerosArbitrableProxy.rule(disputeID, ruling)`.
3.  **Auto-Settlement**: The proxy automatically calls `BaseEscrow.releaseAsDisputeResolver` or `BaseEscrow.cancelAsDisputeResolver`.
4.  **Finalization**: `BaseEscrow` transitions the escrow state and executes the settlement.

*Note: If automatic settlement fails (e.g., due to gas limits), anyone can call `KlerosArbitrableProxy.propagateRuling(workflowId, escrowContract)` to retry the settlement.*

---

## Integration Details

### Pay-at-Proxy Rationale

Kleros arbitration fees vary and must be paid in ETH at the time of dispute creation. To ensure exact payment and avoid complex fee management in `BaseEscrow`, we use a direct payment model at the proxy level. This allows participants to pay the exact fee required by Kleros at that moment.

### Security & Authorization

- **Dispute Creation**: Associated escrow participants (Sender/Recipient) or the registered Escrow Contract can call `createDispute`.
- **Ruling**: Only the registered `IArbitrator` can call `rule`.
- **Settlement**: `BaseEscrow` only accepts settlement calls from the currently assigned `disputeResolver` (the proxy).

---

## Troubleshooting

### "Unknown dispute" during rule()
Ensure the `workflowId` and `escrowContract` were correctly mapped during `createDispute`. The proxy correctly handles `workflowId` 0.

### Ruling not reflecting in BaseEscrow
If Kleros has ruled but the escrow is still `DISPUTED`, use the `propagateRuling` function on the proxy to manually push the resolution.

---

## References

- [ERC-792 Arbitration Standard](https://erc792.com/)
- [Kleros Developer Portal](https://developer.kleros.io/)
