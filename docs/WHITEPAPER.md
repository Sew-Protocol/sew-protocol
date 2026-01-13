# Sew Protocol Whitepaper

**Version:** 1.0  
**Last Updated:** 2026-01-06  
**Network:** Base (Ethereum L2)  
**Status:** Pre-Mainnet

---

## Vision & Why

We want to see accelerating consumer adoption of Ethereum for payments. The biggest problem is risk of lost money through errors or fraud. We want to enable that protection in an Ethereum-native way. It's genuinely decentralised, opensource, ethical and human first. No monitoring or unclear terms and conditions. No lock in. We introduce new primitives that augment the already proven account abstraction primitives (and also function independently with legacy EOA).

Sew Protocol provides the foundational infrastructure to make Ethereum payments safe for everyday purchases, enabling trustless transactions for physical goods while maintaining the decentralized, transparent, and user-controlled principles of Web3.

---

## Executive Summary

Sew Protocol is a decentralized, trustless escrow system built on Base that enables secure peer-to-peer transactions for everyday purchases with built-in dispute resolution, optional yield generation, and comprehensive onchain governance. The protocol addresses the fundamental trust problem in blockchain transactions by providing a secure, transparent, and flexible escrow mechanism that protects both buyers and sellers while maintaining the decentralized ethos of Web3.

**Primary Use Case**: Safe everyday purchases of physical goods, enabling consumers to use Ethereum for payments with protection against fraud and errors.

**Key Innovations:**
- **Modular Architecture**: Pluggable resolution, yield, and distribution modules
- **Snapshot Immutability**: Escrow rules locked at creation, immune to governance changes
- **Multi-Token Support**: Escrow any ERC20 token with a single interface
- **Optional Yield Generation**: Earn yield on escrowed funds via Aave integration
- **Decentralized Dispute Resolution**: Multi-level escalation system with fair resolver selection
- **Governance-Controlled Evolution**: Time-delayed, transparent protocol upgrades

---

## 1. Introduction

### 1.1 The Trust Problem in Blockchain Transactions

Blockchain technology has revolutionized digital transactions by enabling trustless, peer-to-peer value transfer. However, this trustlessness creates a fundamental challenge: **onchain transactions are irreversible**. While this immutability provides security and finality, it creates significant friction for everyday purchases of physical goods where:

- **Buyers** need protection against non-delivery, damaged goods, or misrepresented items
- **Sellers** need assurance of payment before shipping physical products
- **Both parties** need a mechanism to resolve disputes fairly without relying on centralized intermediaries

Traditional solutions rely on centralized intermediaries (e.g., payment processors, escrow services, marketplaces), which reintroduce trust assumptions, monitoring, unclear terms, and lock-in - defeating the purpose of decentralized systems.

### 1.2 Current State of Escrow on Ethereum

Existing escrow solutions on Ethereum suffer from several limitations:

1. **Fragmentation**: Each marketplace or protocol implements custom escrow logic, creating silos
2. **Lack of Standardization**: No common interface for escrow operations
3. **Limited Dispute Resolution**: Most solutions rely on manual multisig coordination
4. **No Composability**: Difficult to integrate escrow into existing dApps
5. **Poor User Experience**: Complex, inconsistent interfaces across platforms

### 1.3 Our Solution

Sew Protocol provides a **standardized, modular, and governance-controlled** escrow system that:

- Enables secure, reversible payments for everyday purchases of physical goods
- Provides built-in dispute resolution with multiple escalation levels
- Supports automated time-based settlements
- Generates optional yield on escrowed funds
- Maintains composability with account abstraction and existing DeFi protocols
- Works with both account abstraction wallets and legacy EOA wallets
- Evolves transparently through onchain governance
- No monitoring, no unclear terms, no lock-in - genuinely decentralized and human-first

---

## 2. Protocol Overview

### 2.1 Core Principles

The protocol is built on four fundamental principles:

1. **Trustlessness**: No single party controls funds or can unilaterally modify escrow rules
2. **Immutability**: Escrow rules are snapshotted at creation and cannot be changed
3. **Modularity**: Pluggable modules for resolution, yield, and distribution
4. **Transparency**: All operations are onchain and publicly verifiable

### 2.2 Architecture Overview

Sew Protocol is built on a modular architecture that enables safe, trustless transactions for everyday purchases:

#### Core Escrow Contracts (Immutable)
- **BaseEscrow**: Abstract base contract with shared escrow logic, state machine, and module integration
- **EscrowVault**: Multi-token escrow vault supporting any ERC20 token - ideal for marketplaces and multi-token use cases
- **EscrowableERC20**: ERC20 token with built-in escrow functionality - enables token-specific escrow capabilities

**Key Features**:
- Immutable core contracts (no proxies) for maximum security and auditability
- Snapshot semantics: Escrow rules locked at creation, immune to governance changes
- Account abstraction compatible: Works with smart contract wallets and legacy EOAs

#### Resolution Modules (Swappable via Governance)
- **DefaultResolutionModule**: Simple single-resolver system (initial mainnet deployment)
  - Single trusted resolver per escrow
  - Governance-controlled resolver updates
  - Suitable for initial launch and simple disputes

- **DecentralizedResolutionModule**: Advanced multi-resolver system with escalation (future swap-in)
  - Multi-resolver registry with round-robin selection
  - Three-level escalation: Standard → Senior → External resolver
  - Category-based dispute routing
  - Resolver incentive system

**Module Governance**: All modules are immutable. Module upgrades are performed by deploying a new version and swapping via Slow lane (queue + activate, ~9 days). Both queue and activate operations require Timelock execution (ROLE_TIMELOCK), ensuring all module changes are time-delayed and transparent.

#### Supporting Modules (Optional)
- **AaveYieldGenerationModule**: Generates yield on escrowed funds via Aave integration
  - Optional per-escrow yield generation
  - Protected by exposure caps and pause mechanisms
  - Governance-controlled enable/disable

- **DefaultYieldDistributionModule**: Configurable yield distribution to recipients
  - Percentage-based allocation
  - Multiple recipients support
  - Immutable at escrow creation

- **ResolverIncentiveModule**: Tracks and distributes payments to resolvers (future, with DecentralizedResolutionModule)
  - Resolver activity tracking
  - Automatic payment distribution
  - Incentive alignment for fair resolution

### 2.3 Key Guarantees

The protocol provides the following guarantees:

1. **Fund Safety**: Escrowed funds are held in smart contracts and cannot be accessed without proper authorization
2. **Rule Immutability**: Once an escrow is created, its rules (modules, timeouts, resolver) cannot be changed by any actor, including governance
3. **Governance Bounds**: All governance changes are time-delayed and affect only new escrows
4. **Emergency Controls**: Guardian can pause protocol or reduce risk, but cannot increase risk or unpause

---

## 3. Protocol Architecture

### 3.1 Core Escrow Contracts

#### BaseEscrow

The abstract base contract provides the foundation for all escrow functionality:

- **Multi-token support**: Escrow any ERC20 token
- **State machine**: Manages escrow lifecycle (Pending → Funded → Disputed → Resolved/Cancelled)
- **Dispute resolution**: Integrates with resolution modules
- **Fee management**: Tracks and collects protocol fees
- **Module integration**: Pluggable resolution, yield, and distribution modules

#### EscrowVault

A multi-token escrow vault that supports escrowing multiple different tokens:

- **Use Case**: When you need to escrow multiple different tokens in a single contract
- **Features**: Per-token fee tracking, batch operations, Aave yield integration
- **Deployment**: Immutable (no proxies)

#### EscrowableERC20

An ERC20 token with built-in escrow functionality:

- **Use Case**: When you want a token that has escrow capabilities built-in
- **Features**: Standard ERC20 functionality + `createEscrow()` function
- **Deployment**: Factory pattern for easy token creation

### 3.2 Resolution Modules

#### DefaultResolutionModule (Initial Deployment)

A simple, single-resolver resolution module:

- **Resolver Assignment**: Single resolver per escrow
- **Governance-Controlled**: Resolver updates require governance approval
- **Use Case**: Simple disputes that don't need escalation

#### DecentralizedResolutionModule (Future Swap-In)

An advanced decentralized resolution system (in separate package, **not included in initial mainnet release**. When ready, will be deployed and swapped in via Slow lane governance - queue + activate via Timelock, ~9 days):

- **Resolver Registry**: Standard and senior resolvers
- **Round-Robin Selection**: Fair distribution of disputes
- **Governance**: Uses same pattern as other modules - deploy new version and swap via Slow lane (queue + activate via Timelock, ~9 days total)
- **Three-Level Escalation**: Standard → Senior → External
- **Category-Based Assignment**: Dynamic resolution table
- **Resolver Incentives**: Automatic payment distribution

### 3.3 Yield Generation

#### AaveYieldGenerationModule

Optional yield generation on escrowed funds:

- **Integration**: Deposits escrowed funds to Aave for yield
- **Protection**: Exposure caps and pause mechanisms
- **Governance-Controlled**: Can be enabled/disabled via governance
- **Use Case**: Generate yield on funds locked in escrow

### 3.4 Snapshot Semantics

A critical design feature: **module addresses and settings are snapshotted at escrow creation**:

- When an escrow is created, the current module addresses are stored in the escrow record
- These addresses **cannot be changed** after creation
- Governance can swap modules, but this only affects **new escrows**
- Existing escrows continue using their snapshotted modules

This ensures that:
- Governance cannot retroactively change escrow rules
- Users can trust that their escrow rules will remain unchanged
- Protocol evolution doesn't break existing escrows

---

## 4. Key Features

### 4.1 Multi-Token Support

The protocol supports escrowing **any ERC20 token**:

- Standard ERC20 tokens
- Custom tokens with specific features
- Single interface for all tokens
- Per-token fee tracking

### 4.2 Dispute Resolution

Built-in dispute resolution with multiple options:

- **Simple Resolution**: Single resolver for straightforward disputes
- **Advanced Resolution**: Multi-resolver system with escalation (future)
- **Escalation Paths**: Standard → Senior → External resolver
- **Fair Selection**: Round-robin resolver assignment

### 4.3 Optional Yield Generation

Escrowed funds can generate yield via Aave:

- **Optional**: Yield generation can be enabled/disabled per escrow
- **Protected**: Exposure caps and pause mechanisms
- **Transparent**: All yield operations are onchain
- **Distributable**: Yield can be distributed to recipients

### 4.4 Automated Settlements

Time-based automatic settlements:

- **Auto-Release**: Automatic release after timeout (if configured)
- **Auto-Cancel**: Automatic cancellation if not funded within timeout
- **Configurable**: Timeouts can be set per escrow

### 4.5 Attachments & Evidence

Support for dispute evidence:

- **IPFS Integration**: Store evidence on IPFS
- **Hash Verification**: Onchain hash verification
- **Multiple Attachments**: Support for multiple evidence files

### 4.6 Governance-Controlled Evolution

Protocol evolution through onchain governance:

- **Time-Delayed**: All changes require timelock delays
- **Transparent**: All proposals and votes are onchain
- **Bounded**: Changes affect only new escrows
- **Emergency Controls**: Guardian can pause or reduce risk

---

## 5. Governance Model

### 5.1 Governance Structure

The protocol uses a multi-layered governance system:

1. **OpenZeppelin Governor**: Token-based voting for proposals
2. **TimelockController**: Time-delayed execution (48h standard, ~9 days slow lane)
3. **Guardian Multisig**: Emergency controls (down-only)

### 5.2 Governance Lanes

#### Emergency Lane (0h delay, Guardian only)
- Pause protocol
- Disable features (e.g., Aave)
- Lower exposure caps
- **Down-only**: Cannot unpause, enable features, or raise caps

#### Standard Lane (48h delay, Timelock)
- Parameter changes
- Unpause protocol
- Fee configuration updates
- Operational configuration

#### Slow Lane (~9 days delay, Timelock)
- Module swaps (all modules use this pattern)
  - Process: Deploy new module → Queue (48h delay via Timelock) → Wait 7 days → Activate (48h delay via Timelock)
  - Total time: ~9 days wall-clock (48h + 7d + 48h)
  - Both queue and activate require Timelock execution (ROLE_TIMELOCK)
  - All modules are immutable; upgrades are performed by deploying a new version and swapping
- Fee recipient changes
- Critical parameter changes

### 5.3 Governance Guarantees

1. **No In-Flight Escrow Modification**: Governance cannot change rules for existing escrows
2. **Snapshot at Creation**: Module addresses locked per escrow
3. **Time-Delayed Execution**: All non-emergency changes require timelock
4. **Down-Only Emergency Controls**: Guardian can only reduce risk

---

## 6. Security

### 6.1 Security Goals

Sew Protocol is designed with the following security goals:

1. **Escrow Correctness**: Funds are correctly tracked and cannot be double-spent or lost due to state machine errors
2. **Immutability of In-Flight Escrows**: Escrow rules (modules, timeouts, resolver) cannot be changed after creation by any actor, including governance
3. **Bounded Governance Changes**: All governance changes are time-delayed and bounded. Changes affect only new escrows
4. **Safe Dispute Resolution**: Dispute resolution is handled by authorized resolvers with proper access control. Resolution logic cannot be manipulated
5. **Safe External Integrations**: External integrations (e.g., Aave) are protected by caps, pause mechanisms, and proper accounting. Failures in external protocols do not result in fund loss
6. **No Per-Escrow Admin Overrides**: No function exists that allows governance to modify individual escrow rules after creation
7. **Guardian Down-Only Powers**: Emergency controls can only reduce risk, never increase it. Guardian cannot unpause, enable features, or raise caps
8. **Reentrancy Protection**: Critical functions use reentrancy guards and follow checks-effects-interactions pattern
9. **Access Control Integrity**: Role-based access control is properly enforced. Deployer roles are revoked after deployment
10. **Time-Delayed Governance**: All non-emergency changes execute through onchain timelock (48 hours for Standard lane, ~9 days for Slow lane)

### 6.2 Security Architecture

#### Immutable Core Contracts
- **BaseEscrow**, **EscrowVault**, **EscrowableERC20**: Deployed immutably (no proxies)
- **No Upgrade Risk**: Core escrow logic cannot be changed after deployment
- **Auditability**: Immutable contracts are easier to audit and verify

#### Immutable Modules
- **All modules are immutable**: Upgrades are performed by deploying a new version and swapping via Slow lane (~9 days)
- **Unified Governance**: All modules use the same governance pattern (queue + activate via Timelock)
- **Timelock-Only Execution**: Both queue and activate operations require Timelock execution (ROLE_TIMELOCK), ensuring all module changes are time-delayed and transparent
- **Snapshot Semantics**: Module addresses are snapshotted at escrow creation and cannot be changed
- **Process**: Deploy new module → Queue (48h delay via Timelock) → Wait 7 days → Activate (48h delay via Timelock) = ~9 days total

#### Governance Security
- **Time-Delayed Execution**: All changes require timelock delays (48h Standard, ~9 days Slow)
- **Bounded Changes**: All parameter changes are bounded onchain
- **Emergency Controls**: Guardian can pause or reduce risk, but cannot increase risk
- **Transparent**: All proposals and votes are onchain and publicly verifiable

#### External Integration Security
- **Aave Integration**: Protected by exposure caps and pause mechanisms
- **Cap Enforcement**: Deposits enforce `exposure[token] + amount <= cap[token]`
- **Guardian Controls**: Guardian can disable Aave or lower caps immediately
- **No Direct Fund Risk**: External protocol failures don't result in direct fund loss

### 6.3 Trust Model

#### What Users Must Trust
1. **Token Contracts**: ERC20 tokens behave as specified (standard ERC20 required)
2. **Chain Liveness**: Base mainnet remains operational and accessible
3. **Block Timestamps**: `block.timestamp` is reasonably accurate for auto-settlement
4. **External Protocols**: If yield enabled, Aave protocol functions correctly
5. **Governance Process**: Token holders vote honestly and timelock executes correctly
6. **Resolver Honesty**: Dispute resolution relies on resolver behavior (mitigated by escalation and incentives)

#### What Users Do NOT Need to Trust
1. **Team/Developers**: Cannot modify in-flight escrow rules. Cannot unilaterally change modules
2. **Governance**: Cannot change rules of existing escrows. Can only affect new escrows
3. **Guardian**: Cannot steal funds, unpause without timelock, or increase risk. Powers are strictly down-only
4. **Deployer**: All deployer roles are revoked after deployment
5. **Future Code Changes**: Core contracts are non-upgradeable. Module upgrades are time-delayed and transparent

### 6.4 Security Measures

#### Code Security
- **Comprehensive Testing**: Hardhat + Foundry test suites with high coverage
- **Static Analysis**: Slither analysis configured and run regularly
- **Fuzz Testing**: Foundry fuzz tests for critical paths
- **Formal Verification**: Considered for critical invariants

#### Operational Security
- **Emergency Procedures**: Clear runbooks for emergency situations
- **Guardian Multisig**: Hardware wallet-based multisig for emergency controls
- **Monitoring**: Onchain monitoring for suspicious activity
- **Incident Response**: Documented procedures for security incidents

#### Audit & Verification
- **Security Audits**: Multiple audit phases planned before mainnet
- **Bug Bounties**: Bug bounty program for ongoing security
- **Public Verification**: All contracts verified on Basescan
- **Security Documentation**: Comprehensive security model and threat analysis

### 6.5 Known Risks & Mitigations

#### Smart Contract Risks
- **Reentrancy**: Mitigated by ReentrancyGuard and CEI pattern
- **Access Control**: Mitigated by role-based access control and role revocation
- **Integer Overflow**: Mitigated by Solidity 0.8.33 built-in checks
- **Front-Running**: Mitigated by commit-reveal patterns where applicable

#### Governance Risks
- **Governance Attacks**: Mitigated by timelock delays and proposal thresholds
- **Malicious Proposals**: Mitigated by voting requirements and timelock delays
- **Guardian Compromise**: Mitigated by multisig and down-only powers

#### External Risks
- **Aave Protocol Failure**: Mitigated by caps, pause mechanisms, and withdrawal procedures
- **Token Contract Issues**: Mitigated by standard ERC20 requirement and SafeERC20 usage
- **Chain Issues**: Mitigated by Base L2 reliability and monitoring

#### Operational Risks
- **Key Management**: Mitigated by hardware wallets and multisig
- **Human Error**: Mitigated by runbooks, testing, and rehearsals
- **Social Engineering**: Mitigated by security policies and access controls

### 6.6 Security Guarantees

Sew Protocol provides the following security guarantees:

1. **Fund Safety**: Escrowed funds are held in smart contracts and cannot be accessed without proper authorization
2. **Rule Immutability**: Once an escrow is created, its rules cannot be changed by any actor, including governance
3. **Governance Bounds**: All governance changes are time-delayed and affect only new escrows
4. **Emergency Controls**: Guardian can pause protocol or reduce risk, but cannot increase risk or unpause
5. **No Per-Escrow Overrides**: No governance actor can modify rules for a specific escrow after creation
6. **Transparent Operations**: All operations are onchain and publicly verifiable

---

## 7. Use Cases

### 7.1 Everyday Physical Goods Purchases (Primary Use Case)

**Scenario**: Consumer purchases physical goods from seller using Ethereum

1. Buyer creates escrow with seller address and payment amount
2. Buyer funds escrow (using account abstraction wallet or legacy EOA)
3. Seller ships physical goods
4. Buyer receives goods, inspects, and releases escrow
5. If dispute (damaged goods, wrong item, non-delivery): Resolver reviews evidence and makes decision

**Benefits**: 
- Buyer protection against fraud and errors
- Seller assurance of payment before shipping
- No centralized intermediary or monitoring
- Works with any ERC20 token
- Account abstraction compatible

**Example**: Purchasing electronics, clothing, collectibles, or any physical product with Ethereum payment protection.

### 7.2 Marketplace Integration

**Scenario**: Online marketplace integrates Sew Protocol for buyer protection

1. Marketplace creates escrow for each transaction
2. Buyer funds escrow at checkout
3. Seller ships goods
4. Buyer confirms receipt and releases escrow
5. If dispute: Marketplace resolver or protocol resolver handles dispute

**Benefits**: 
- Built-in buyer protection for marketplaces
- Reduces chargeback risk for sellers
- Transparent, onchain dispute resolution
- No payment processor lock-in

### 7.3 Peer-to-Peer Physical Goods Sales

**Scenario**: Person-to-person sale of physical items (e.g., classified ads, social commerce)

1. Buyer creates escrow with seller address
2. Buyer funds escrow
3. Seller ships or delivers goods
4. Buyer verifies and releases escrow
5. If dispute: Resolver reviews evidence (photos, tracking, messages)

**Benefits**: 
- Protection for both parties in P2P transactions
- No need for trusted intermediary
- Works with any Ethereum wallet
- Transparent dispute resolution

---

## 8. Technical Specifications

### 8.1 Network

- **Primary Network**: Base (Ethereum L2)
- **Chain ID**: 8453 (Base Mainnet)
- **Testnet**: Base Sepolia (Chain ID: 84532)

### 8.2 Smart Contract Infrastructure

- **Solidity Version**: 0.8.33
- **EVM Version**: Cancun (supports `mcopy` instruction)
- **OpenZeppelin Contracts**: v5.4.0
- **Compiler Settings**: Optimizer enabled (50,000 runs), via-IR enabled

### 8.3 Contract Deployment

- **Core Contracts**: Immutable (no proxies)
- **Modules**: Swappable via governance
- **Deployment Tool**: hardhat-deploy
- **Verification**: Basescan verification supported

### 8.4 Testing

- **Hardhat Tests**: TypeScript-based integration tests
- **Foundry Tests**: Solidity-based unit and fuzz tests
- **Coverage**: Comprehensive test coverage
- **Static Analysis**: Slither configured

---

## 9. Roadmap

### Phase 1: Initial Mainnet Deployment

**Goal**: Launch Sew Protocol on Base mainnet with core escrow functionality

**Deliverables**:
- Core escrow contracts (immutable, no proxies)
- DefaultResolutionModule (single-resolver system)
- Basic governance infrastructure (Governor, Timelock, Guardian)
- Emergency controls (pause, disable Aave, lower caps)
- Aave yield generation integration (optional)
- Comprehensive testing and security audits
- Operational runbooks and emergency procedures

**Status**: Pre-mainnet, awaiting audits and drills

**Timeline**: Q1 2026 (target)

---

### Phase 2: Extensive Simulation and Testing of Decentralized Dispute Resolution Network

**Goal**: Prove DecentralizedResolutionModule in isolation before mainnet integration

**Deliverables**:
- Deploy DecentralizedResolutionModule in separate package
- Extensive testing with simulated disputes
- Resolver network testing and validation
- Performance and gas optimization
- Security audits of decentralized resolution system
- Resolver incentive system testing
- Real-world dispute scenario simulations

**Status**: Module extracted, testing in progress

**Timeline**: Q2-Q3 2026 (target)

---

### Phase 3: Mainnet Migration to Decentralized Dispute Resolution Module

**Goal**: Swap DecentralizedResolutionModule into mainnet protocol via governance

**Deliverables**:
- Deploy DecentralizedResolutionModule contract
- Governance proposal to queue module swap (48h delay via Timelock)
- Community vote and timelock execution of queue
- Wait 7 days (slow lane delay enforced onchain)
- Governance proposal to activate module swap (48h delay via Timelock)
- Community vote and timelock execution of activate
- Resolver network onboarding
- Incentive system activation
- Monitoring and optimization

**Status**: Planned for after Phase 2 completion

**Timeline**: Q4 2026 (target, after Phase 2 validation)

**Process**: 
1. Deploy new DecentralizedResolutionModule
2. Queue module swap (48h delay via Timelock) - requires Timelock execution (ROLE_TIMELOCK)
3. Wait 7 days (slow lane delay)
4. Activate module swap (48h delay via Timelock) - requires Timelock execution (ROLE_TIMELOCK)
5. Total time: ~9 days wall-clock (48h + 7d + 48h)

**Note**: All modules are immutable. Module upgrades are performed by deploying a new version and swapping via Slow lane (queue + activate via Timelock). Both queue and activate operations require Timelock execution (ROLE_TIMELOCK), ensuring all module changes are time-delayed and transparent. All existing escrows continue using DefaultResolutionModule (snapshot preserved). Only new escrows use DecentralizedResolutionModule.

---

## 10. Tokenomics

### 10.1 Fee Structure

#### Escrow Fees
- **Escrow Fee**: 1% of escrow amount (100 basis points)
- **Fee Recipient**: Protocol treasury (governance-controlled)
- **Collection**: Fees are collected at escrow creation and held in protocol treasury

#### Yield Distribution
- **Yield Generation**: Optional per-escrow (via Aave integration)
- **Protocol Share**: 30% of generated yield goes to protocol treasury
- **User Share**: 70% of generated yield distributed to escrow participants (buyer/seller) based on escrow configuration

#### Dispute Resolution Fees (After DecentralizedResolutionModule Launch)

**Escalation Fees**:
- **Level 1 Escalation** (Standard → Senior): Fee set by governance
- **Level 2 Escalation** (Senior → External): Fee set by governance
- **Fee Distribution**:
  - 50% to resolver network (incentives for resolvers)
  - 50% to protocol treasury

**Resolver Incentives**:
- Resolvers receive 50% of escalation fees as incentives
- Payment distribution based on resolver activity and quality metrics
- Automatic distribution via ResolverIncentiveModule

### 10.2 Governance Token (SEW)

**Purpose**: Governance token for protocol decision-making

**Governance Functions**:
- Proposal creation and voting
- Parameter changes
- Module swaps
- Fee recipient updates
- Emergency response coordination

**Token Distribution**: TBD (to be determined before mainnet launch)

**Voting Mechanics**:
- Token-based voting (1 token = 1 vote)
- Quorum requirements
- Proposal thresholds
- Timelock execution

### 10.3 Revenue Streams

**Protocol Revenue**:
1. **Escrow Fees**: 1% of all escrow amounts
2. **Yield Share**: 30% of generated yield (when yield enabled)
3. **Escalation Fees**: 50% of escalation fees (after DecentralizedResolutionModule launch)

**Revenue Use**:
- Protocol development and maintenance
- Security audits and bug bounties
- Resolver network incentives (after DecentralizedResolutionModule)
- Governance operations
- Emergency reserves

### 10.4 Incentive Alignment

**Resolver Incentives** (After DecentralizedResolutionModule):
- 50% of escalation fees distributed to resolvers
- Quality-based payment weighting
- Activity tracking and rewards
- Fair workload distribution via round-robin selection

**User Benefits**:
- Buyer protection for everyday purchases
- Seller payment assurance
- Optional yield generation (70% to users)
- Transparent, onchain dispute resolution

---

## 11. Risks & Limitations

### 11.1 Known Limitations

1. **Reliance on `block.timestamp`**: Auto-settlement features depend on `block.timestamp`, which can be manipulated by miners/validators within a certain range (typically ±15 seconds). This is acceptable for day-level timeouts but should be considered for shorter durations.

2. **Dispute Resolution is a Social Process**: While dispute resolution is executed onchain, the decision-making process (resolver judgment) is inherently social. The protocol provides technical guarantees (access control, time delays, escalation) but cannot eliminate the need for human judgment in disputes.

3. **Governance Can Change Defaults for New Escrows**: By design, governance can change default modules, timeouts, and other parameters. These changes affect only escrows created after the change (snapshot immutability), but users should be aware that protocol defaults may evolve.

4. **External Protocol Dependencies**: If yield generation is enabled, the protocol depends on Aave functioning correctly. Aave protocol failures or exploits could affect yield generation, though caps and pause mechanisms limit exposure.

5. **Token Support Limitations**: The protocol assumes standard ERC20 behavior. Non-standard tokens (fee-on-transfer, rebasing) may not be fully supported. See Security Model for details.

6. **Gas Costs**: Complex operations (dispute resolution with multiple payouts, large attachment arrays) may have high gas costs. Users should be aware of gas implications, especially on mainnet.

7. **Account Abstraction Compatibility**: While the protocol works with both account abstraction wallets and legacy EOAs, some advanced features may require smart contract wallet capabilities.

### 11.2 Risk Mitigations

- **Comprehensive Testing**: Extensive test coverage and fuzz testing
- **Security Audits**: Multiple audit phases planned
- **Time-Delayed Governance**: All changes require timelock delays
- **Emergency Controls**: Guardian can pause or reduce risk
- **Immutable Core Contracts**: Core escrow logic cannot be changed

---

## 12. Conclusion

Sew Protocol provides a secure, transparent, and flexible solution to the trust problem in blockchain transactions, specifically enabling safe everyday purchases of physical goods with Ethereum. By combining immutable core contracts with modular, governance-controlled components, the protocol enables trustless peer-to-peer transactions while maintaining the ability to evolve and improve over time.

**Key Differentiators:**

1. **Immutability Where It Matters**: Core escrow rules are immutable, but the protocol can evolve
2. **Modular Design**: Pluggable modules enable flexibility without compromising security
3. **Unified Module Governance**: All modules are immutable and use the same Slow lane swap pattern (queue + activate via Timelock, ~9 days). Both queue and activate require Timelock execution, ensuring all module changes are time-delayed and transparent.
4. **Governance-Controlled Evolution**: Transparent, time-delayed protocol upgrades
5. **Comprehensive Security**: Multiple layers of security and emergency controls
6. **User-Centric Design**: Focus on protecting both buyers and sellers in everyday purchases
7. **Account Abstraction Compatible**: Works with smart contract wallets and legacy EOAs
8. **Genuinely Decentralized**: No monitoring, no unclear terms, no lock-in - ethical and human-first

**Vision**: Sew Protocol is designed to accelerate consumer adoption of Ethereum for payments by solving the fundamental problem of lost money through errors or fraud. We introduce new primitives that augment account abstraction, enabling safe, trustless transactions for physical goods while maintaining the decentralized, transparent, and user-controlled principles of Web3.

The protocol is designed to become a foundational piece of infrastructure for trustless transactions on Ethereum and Layer 2 networks, specifically enabling safe everyday purchases and improving the user experience for decentralized commerce.

---

## 13. References & Resources

### Documentation

- [Technical Overview](TECHNICAL_OVERVIEW.md) - Detailed technical documentation
- [Security Model](SECURITY_MODEL.md) - Comprehensive security analysis
- [Governance Model](governance.md) - Governance structure and procedures
- [Contracts Summary](CONTRACTS_SUMMARY.md) - Contract overview
- [Upgrade Policy](UPGRADE_POLICY.md) - Upgrade procedures

### Code & Deployment

- **Repository**: [GitHub Repository](https://github.com/your-org/hardhat-deploy-hybrid)
- **Network**: Base Mainnet (Chain ID: 8453)
- **Testnet**: Base Sepolia (Chain ID: 84532)

### Security

- [Security Policy](../SECURITY.md) - Security contact and disclosure policy
- [Audit Documentation](AUDIT.md) - Audit status and reports

### Governance

- [Governance Surface Map](GOVERNANCE_SURFACE_MAP.md) - Complete function mapping
- [Operational Runbooks](../governance/runbooks/) - Step-by-step procedures

---

## Appendix A: Glossary

- **Escrow**: Funds held by a third party until conditions are met
- **Snapshot Semantics**: Module addresses locked at escrow creation
- **Resolution Module**: Contract that handles dispute resolution logic
- **Governance Lane**: Different delay periods for different types of changes
- **Timelock**: Time-delayed execution mechanism
- **Guardian**: Emergency control role with down-only powers

---

## Appendix B: Contract Addresses

*To be filled after mainnet deployment*

- **EscrowVault**: TBD
- **EscrowableERC20**: TBD
- **DefaultResolutionModule**: TBD
- **Governor**: TBD
- **TimelockController**: TBD

---

**Document Version**: 1.0  
**Last Updated**: 2026-01-06  
**Status**: Pre-Mainnet  
**Next Review**: After mainnet deployment

---

*This whitepaper is a living document and will be updated as the protocol evolves.*



