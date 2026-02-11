## Sew Protocol — Smart Contracts

This repository contains the core smart contracts for Sew Protocol, including the protected payment system, modular execution architecture, governance token, and full test suite.

Sew Protocol is designed to make everyday onchain payments safer and easier to understand by introducing a clear payment lifecycle. Instead of payments being final immediately, funds can be held securely until conditions are met — such as confirmation, time windows, or resolution of a problem. This enables real-world use cases like peer-to-peer commerce, service payments, and trusted transactions without relying on intermediaries.

The contracts in this repository include:

* Core payment contracts that manage protected transfers and their lifecycle
* Modular components for release rules, resolution mechanisms, and yield integration
* Governance token and protocol control infrastructure
* Safety and monitoring features for pause, recovery, and upgrades affecting future payments only
* Comprehensive unit, fuzz, and integration tests

The architecture is designed to be modular and composable, allowing new modules to be introduced over time without affecting existing in-progress payments. This ensures predictability, transparency, and long-term stability for users and integrators.

This repository serves as the reference implementation of Sew Protocol’s onchain payment framework.



## Security Model

The protocol is built on three core security principles:

1. **Containment over prevention**: Failures are contained rather than prevented
2. **Determinism over discretion**: Funds move according to predefined rules
3. **Isolation over shared risk**: Each escrow is independent; failures don't cascade

Each escrow captures its configuration (modules, fees, timeouts) at creation time, ensuring that global updates never affect existing agreements. For details, see [docs/security/SECURITY_MODEL.md](./docs/security/SECURITY_MODEL.md).

## Documentation Structure

Comprehensive documentation is organized in [`docs/`](./docs/) with an [INDEX](./docs/INDEX.md) to help you navigate:

### For Developers & Auditors
- **[docs/security/SECURITY_MODEL.md](./docs/security/SECURITY_MODEL.md)** - Security principles, threat model, and per-escrow isolation
- **[docs/architecture/](./docs/architecture/)** - System design, contract dependencies, and technical overview
- **[docs/analysis/](./docs/analysis/)** - Design decisions, fixes, and technical analysis

### For Operations & Deployment
- **[docs/operations/](./docs/operations/)** - Deployment procedures, monitoring, and operational runbooks
- **[docs/setup/](./docs/setup/)** - Deployment checklists and prerequisites

### For Integration & Development
- **[docs/guides/](./docs/guides/)** - Wallet integration, wallet UX, mobile app integration
- **[docs/reference/](./docs/reference/)** - Quick references, test summaries, interface maps

### By Phase & Status
- **[docs/phase-delivery/](./docs/phase-delivery/)** - Phase 2, 3, 4 deliverables, implementation plans, test reports

### Full Navigation
See **[docs/INDEX.md](./docs/INDEX.md)** for complete documentation index with 100+ pages organized by topic, audience, and use case.

## Quick Start

```bash
# Install dependencies
pnpm install

# Run tests
pnpm test

# Build contracts
pnpm build

# Run linter
pnpm lint
```

## Project Status

- **Test Suite**: 1186/1194 tests passing (99.3%)
- **Phase 4 Complete**: Per-escrow configuration isolation fully implemented
- **Security Model**: Fully documented and enforced in code
