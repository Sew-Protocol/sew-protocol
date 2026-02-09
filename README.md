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


