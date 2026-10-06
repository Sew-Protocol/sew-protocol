# Multi-Escrow Documentation Index

Welcome to the Multi-Escrow protocol documentation. This index helps you navigate the
documentation organized by topic and use case. Paths are relative to `docs/`.

## 🚀 Quick Start

**First time here?** Start with these documents:

- [README.md](./README.md) - Overview and getting started
- [PROTOCOL_OVERVIEW.md](./PROTOCOL_OVERVIEW.md) - Protocol overview and system map
- [WHITEPAPER.md](./WHITEPAPER.md) - Protocol design and vision
- [SECURITY.md](./SECURITY.md) - Security policies and best practices
- [overview/START_HERE.md](./overview/START_HERE.md) - Guided starting point

## 📚 Documentation Structure

### 📋 Overview
**Understanding the protocol and its design**

- [overview/COMPLETE_SYSTEM_SUMMARY.md](./overview/COMPLETE_SYSTEM_SUMMARY.md) - Full system architecture and design
- [overview/MULTI_VAULT_ARCHITECTURE.md](./overview/MULTI_VAULT_ARCHITECTURE.md) - Multi-vault system design
- [overview/MULTI_VAULT_USER_BENEFITS.md](./overview/MULTI_VAULT_USER_BENEFITS.md) - Benefits and use cases
- [overview/CONTRACT_REFERENCE_GUIDE.md](./overview/CONTRACT_REFERENCE_GUIDE.md) - Contract reference and interfaces

### 🏗️ System Architecture
**Deep dives into architecture, design, and contract organization**

- [architecture/README.md](./architecture/README.md) - Architecture guides overview
- [architecture/ARCHITECTURE_OVERVIEW.md](./architecture/ARCHITECTURE_OVERVIEW.md) - System architecture details
- [architecture/ARCHITECTURAL_PRINCIPLES.md](./architecture/ARCHITECTURAL_PRINCIPLES.md) - Core design principles
- [architecture/TECHNICAL_OVERVIEW.md](./architecture/TECHNICAL_OVERVIEW.md) - Technical architecture
- [architecture/CONTRACT_DEPENDENCY_MAP.md](./architecture/CONTRACT_DEPENDENCY_MAP.md) - Contract dependencies
- [architecture/CONTRACTS_SUMMARY.md](./architecture/CONTRACTS_SUMMARY.md) - Summary of every contract
- [architecture/CONTRACT_NAMES_DESCRIPTIONS.md](./architecture/CONTRACT_NAMES_DESCRIPTIONS.md) - Contract naming conventions
- [architecture/CONTRACT_QUICK_REFERENCE.md](./architecture/CONTRACT_QUICK_REFERENCE.md) - Quick contract reference
- [architecture/ESCROW_CREATION_AND_SETTINGS.md](./architecture/ESCROW_CREATION_AND_SETTINGS.md) - Escrow creation flow
- [architecture/PROTOCOL_FEES.md](./architecture/PROTOCOL_FEES.md) - Fee structures and calculations
- [architecture/PROTOCOL_MODULARITY.md](./architecture/PROTOCOL_MODULARITY.md) - Module system and swap mechanics
- [architecture/YIELD_DISTRIBUTION.md](./architecture/YIELD_DISTRIBUTION.md) - Yield distribution mechanisms
- [architecture/YIELD_MODULE_ARCHITECTURE.md](./architecture/YIELD_MODULE_ARCHITECTURE.md) - Yield module design
- [architecture/PER_ESCROW_MODULE_SELECTION.md](./architecture/PER_ESCROW_MODULE_SELECTION.md) - Per-escrow module selection

### ⚙️ Operations & Deployment
**Running, monitoring, and operating the protocol**

- [operations/DEPLOYMENT.md](./operations/DEPLOYMENT.md) - Deployment procedures
- [operations/OP_STACK_L2_GUIDE.md](./operations/OP_STACK_L2_GUIDE.md) - OP Stack L2 operations
- [operations/MONITOR_SETUP.md](./operations/MONITOR_SETUP.md) - Monitoring and alerts setup
- [operations/PHASE2_MONITORING_ALERTING.md](./operations/PHASE2_MONITORING_ALERTING.md) - Monitoring systems
- [operations/PHASE4_RUNBOOKS_COMMUNICATION.md](./operations/PHASE4_RUNBOOKS_COMMUNICATION.md) - Operational runbooks
- [deployment/README.md](./deployment/README.md) - Deployment guides overview
- [deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md](./deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md) - Base Sepolia core testnet guide
- [deployment/BASE_SEPOLIA_DEPLOYMENT_GUIDE.md](./deployment/BASE_SEPOLIA_DEPLOYMENT_GUIDE.md) - Base Sepolia deployment guide
- [deployment/DEPLOYMENT_INSTRUCTIONS.md](./deployment/DEPLOYMENT_INSTRUCTIONS.md) - Deployment instructions
- [deployment/BRANCHING_AND_RELEASE_DISCIPLINE.md](./deployment/BRANCHING_AND_RELEASE_DISCIPLINE.md) - Branch and release discipline
- [deployment/RELEASES.md](./deployment/RELEASES.md) - Release history

### 🔌 Integration & Wallet Guides
**Integrating with wallets, frontend, and user experience**

- [guides/WALLET_UX_README.md](./guides/WALLET_UX_README.md) - Wallet UX overview
- [guides/WALLET_INTEGRATION_GUIDE.md](./guides/WALLET_INTEGRATION_GUIDE.md) - Wallet integration guide
- [guides/WALLET_INTEGRATION_QUICK_REF.md](./guides/WALLET_INTEGRATION_QUICK_REF.md) - Wallet integration quick reference
- [guides/VIEM_WAGMI_QUICK_START.md](./guides/VIEM_WAGMI_QUICK_START.md) - Viem/Wagmi quick start
- [guides/ACCOUNT_ABSTRACTION_GUIDE.md](./guides/ACCOUNT_ABSTRACTION_GUIDE.md) - Account abstraction integration
- [guides/KLEROS_INTEGRATION_GUIDE.md](./guides/KLEROS_INTEGRATION_GUIDE.md) - Kleros integration guide
- [guides/CODING_STANDARDS.md](./guides/CODING_STANDARDS.md) - Solidity coding standards
- [guides/CONTRIBUTING.md](./guides/CONTRIBUTING.md) - Contribution process

### ⚖️ Governance
- [governance/README.md](./governance/README.md) - Governance overview
- [governance/GOVERNANCE.md](./governance/GOVERNANCE.md) - Governance model
- [governance/GOVERNANCE_CONSTRAINTS.md](./governance/GOVERNANCE_CONSTRAINTS.md) - Governance constraints
- [governance/GOVERNANCE_PROCESS.md](./governance/GOVERNANCE_PROCESS.md) - Proposal lifecycle and voting
- [governance/GOVERNANCE_SURFACE_MAP.md](./governance/GOVERNANCE_SURFACE_MAP.md) - Function-to-role-to-lane mapping
- [governance/IMPLEMENTATION_STATUS.md](./governance/IMPLEMENTATION_STATUS.md) - Governance implementation status

### ⚖️ Dispute Resolution
**The full dispute-resolution subsystem (treated as active)**

- [dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md](./dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md) - Three-round escalation pipeline
- [dispute-resolution/DISPUTE_ECONOMICS.md](./dispute-resolution/DISPUTE_ECONOMICS.md) - Bond, slashing, and incentive mechanics
- [dispute-resolution/DR_V3_COMPLETE_SUMMARY.md](./dispute-resolution/DR_V3_COMPLETE_SUMMARY.md) - End-to-end DR v3 summary
- [dispute-resolution/DR_V3_PARAMETERS.md](./dispute-resolution/DR_V3_PARAMETERS.md) - Production parameter values
- [dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md](./dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md) - Launch-safe default parameters
- [dispute-resolution/KLEROS_INTEGRATION.md](./dispute-resolution/KLEROS_INTEGRATION.md) - Kleros integration design
- [dispute-resolution/APPEAL_GAME_THEORY_BENCHMARKS.md](./dispute-resolution/APPEAL_GAME_THEORY_BENCHMARKS.md) - Appeal incentive game theory
- [dispute-resolution/BOND_VALUATION_SUMMARY.md](./dispute-resolution/BOND_VALUATION_SUMMARY.md) - Bond composition and valuation
- [dispute-resolution/COMPARATIVE_ANALYSIS_DR_SYSTEMS.md](./dispute-resolution/COMPARATIVE_ANALYSIS_DR_SYSTEMS.md) - Comparison with other dispute systems

### 🔒 Security
**Security principles, threat models, and per-escrow isolation**

- [SECURITY_MODEL.md](./SECURITY_MODEL.md) - Core security model and principles
- [security/SECURITY_MODEL.md](./security/SECURITY_MODEL.md) - Original per-escrow isolation reference
- [security/BACKWARD_COMPATIBILITY_ANALYSIS.md](./security/BACKWARD_COMPATIBILITY_ANALYSIS.md) - Backward-compatibility analysis
- [security/PATH_TRAVERSAL_AUDIT.md](./security/PATH_TRAVERSAL_AUDIT.md) - Path-traversal audit
- [security/RECOVERY_FUNCTIONALITY.md](./security/RECOVERY_FUNCTIONALITY.md) - Token recovery design
- [policies/EMERGENCY_POLICY.md](./policies/EMERGENCY_POLICY.md) - Emergency response policy
- [policies/UPGRADE_POLICY.md](./policies/UPGRADE_POLICY.md) - Protocol upgrade policy
- [policies/SECURITY_PRINCIPLES_CHECKLIST.md](./policies/SECURITY_PRINCIPLES_CHECKLIST.md) - Security principles checklist

### 📈 Analysis & Reference
**Technical decisions, standards, and reference material**

- [analysis/DESIGN_DECISIONS.md](./analysis/DESIGN_DECISIONS.md) - Key architectural decisions
- [reference/ADDRESS_VALIDATION_STANDARDS.md](./reference/ADDRESS_VALIDATION_STANDARDS.md) - Address validation standards
- [reference/ERROR_STANDARDIZATION.md](./reference/ERROR_STANDARDIZATION.md) - Error standardization
- [reference/FAILURE_REASON_USAGE_MATRIX.md](./reference/FAILURE_REASON_USAGE_MATRIX.md) - Failure reason usage matrix
- [reference/INTERFACE_DISCOVERY_MAP.md](./reference/INTERFACE_DISCOVERY_MAP.md) - Interface discovery guide
- [reference/INTERFACE_VERSIONING.md](./reference/INTERFACE_VERSIONING.md) - Interface versioning policy
- [reference/MODULE_DEVELOPMENT_GUIDE.md](./reference/MODULE_DEVELOPMENT_GUIDE.md) - How to build a new module
- [reference/MODULE_MAP.md](./reference/MODULE_MAP.md) - Module interface-to-implementation map
- [reference/YIELD_PRESET_EXTENSIBILITY_GUIDE.md](./reference/YIELD_PRESET_EXTENSIBILITY_GUIDE.md) - Yield preset extensibility

### 📁 Additional Directories
- [architecture/](./architecture/) - Architecture and design docs
- [best-practices/](./best-practices/) - Engineering best practices
- [checklists/](./checklists/) - Operational checklists
- [deployment/](./deployment/) - Deployment guides (incl. `dr1/`, `dr2/`, `dr3/`, `ieo/` runbooks)
- [dispute-resolution/](./dispute-resolution/) - Dispute resolution system
- [governance/](./governance/) - Governance documentation
- [guides/](./guides/) - Integration and developer guides
- [implementation/](./implementation/) - Implementation specifications
- [modules/](./modules/) - Module documentation
- [more/](./more/) - Migrations, plans, and status
- [operations/](./operations/) - Operations and monitoring
- [overview/](./overview/) - System overviews
- [phase-delivery/](./phase-delivery/) - Phase delivery documentation
- [policies/](./policies/) - Policies and procedures
- [proposals/](./proposals/) - Protocol proposals
- [reference/](./reference/) - Reference and standards
- [review/](./review/) - Review handoff material
- [reviews/](./reviews/) - Contract review checklists
- [security/](./security/) - Security documentation
- [test/](./test/) - Test documentation
- [testing/](./testing/) - Testing guides
- [token/](./token/) - Token documentation

## 🗄️ Archived Material

Historical point-in-time documents (setup guides, delivery/phase summaries, analysis reports,
security review checklists, naming reviews, and other pre-cleanup material) are preserved in
[archived/](./archived/). Refer to `archived/<name>.md` when you need a specific archived doc.

## 🎯 By Use Case

### "I want to deploy the protocol"
1. Read [operations/DEPLOYMENT.md](./operations/DEPLOYMENT.md)
2. Follow [deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md](./deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md)
3. Review [deployment/RELEASES.md](./deployment/RELEASES.md)

### "I want to integrate a wallet"
1. Read [guides/VIEM_WAGMI_QUICK_START.md](./guides/VIEM_WAGMI_QUICK_START.md) for web3 libraries
2. Review [guides/WALLET_INTEGRATION_GUIDE.md](./guides/WALLET_INTEGRATION_GUIDE.md)

### "I want to understand the architecture"
1. Read [overview/COMPLETE_SYSTEM_SUMMARY.md](./overview/COMPLETE_SYSTEM_SUMMARY.md)
2. Review [architecture/TECHNICAL_OVERVIEW.md](./architecture/TECHNICAL_OVERVIEW.md)
3. Check [architecture/CONTRACT_DEPENDENCY_MAP.md](./architecture/CONTRACT_DEPENDENCY_MAP.md)

### "I want to audit the protocol"
1. Read [SECURITY.md](./SECURITY.md) first
2. Review [SECURITY_MODEL.md](./SECURITY_MODEL.md) and [security/SECURITY_MODEL.md](./security/SECURITY_MODEL.md)
3. Check [reviews/CONTRACT_CHECKLIST.md](./reviews/CONTRACT_CHECKLIST.md)

### "I want to set up monitoring"
1. Follow [operations/MONITOR_SETUP.md](./operations/MONITOR_SETUP.md)
2. Read [operations/PHASE2_MONITORING_ALERTING.md](./operations/PHASE2_MONITORING_ALERTING.md)
3. Review [operations/PHASE4_RUNBOOKS_COMMUNICATION.md](./operations/PHASE4_RUNBOOKS_COMMUNICATION.md)

## 📝 Document Organization

All documents are organized by:
- **Purpose** (overview, architecture, operations, etc.)
- **Audience** (developers, auditors, operators, integrators)
- **Topic** (deployment, integration, analysis, etc.)

Use the directory structure to quickly find documentation relevant to your needs.

## 🔄 Changelog

See [CHANGELOG.md](./CHANGELOG.md) for recent updates and changes to documentation.

## ❓ Questions?

- Check [README.md](./README.md) for general information
- Review [SECURITY.md](./SECURITY.md) for security concerns
- Look in the appropriate directory for your topic
- Check [archived/](./archived/) for historical material

---

**Last Updated**: February 2026
**Status**: Production Ready
