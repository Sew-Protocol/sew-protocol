# Prerequisites for Full Multi-L2 Support

**Status**: Critical groundwork checklist  
**Scope**: What must be done NOW to enable future multi-L2 wallet UX  
**Created**: Feb 4, 2026

---

## Executive Summary

**If we want full multi-L2 support to work seamlessly later, we need to establish these foundations TODAY.**

Some changes are **impossible to retrofit** after mainnet deployment. This document identifies critical prerequisites that should be implemented before or immediately after the current deployment.

---

## Part 1: Contract Architecture Prerequisites

### 1.1 CRITICAL: Deterministic Deployment Pattern (CREATE2)

**Problem**: If contracts are deployed sequentially, they'll have different addresses on each chain.

**Solution**: Use CREATE2 with deterministic salts so same address on all chains.

```solidity
// ❌ CURRENT (sequential deployment)
contract Factory {
  function deploy() external {
    new BaseEscrow(); // Different address on each chain!
  }
}

// ✅ REQUIRED (deterministic)
contract Factory {
  function deployDeterministic(bytes32 salt) external {
    // This GUARANTEES same address on all L2s
    new BaseEscrow{salt: salt}();
  }
}
```

**Status in Current Code**: 
- ✅ EscrowableERC20Factory exists
- ❓ Need to verify if using CREATE2 pattern
- ❌ BaseEscrow/EscrowVault may not have factory

**Action Required**:
```solidity
// Add to BaseEscrow or create factory:
bytes32 constant DEPLOYMENT_SALT = keccak256("BaseEscrow.v1");

// Deploy on all chains with SAME salt
function deployOnAllChains() {
  // Ethereum
  factory.deployDeterministic{salt: DEPLOYMENT_SALT}();
  // Base
  factory.deployDeterministic{salt: DEPLOYMENT_SALT}();
  // Arbitrum
  factory.deployDeterministic{salt: DEPLOYMENT_SALT}();
  // ...result: same address on all chains!
}
```

**Impact**: 
- If not done now: Can't add multi-L2 support later (addresses will diverge)
- If done now: Enables all future multi-L2 features

**Timeline**: Must be done BEFORE mainnet deployment

---

### 1.2 Contract Interface Standardization

**Problem**: Views and getters must be consistent for multicall batching to work.

**Checklist**:

- [ ] **getState(uint256 workflowId)** - Returns workflow state
- [ ] **getBalance(address user)** - Returns user balance
- [ ] **getMetadata(bytes32 key)** - Generic metadata getter
- [ ] **isPaused()** - Returns pause status
- [ ] **getModule(ModuleType type)** - Returns active module
- [ ] **getRecoveryStatus()** - Returns recovery state

**Current Status**:
```bash
$ grep -n "function get" contracts/core/BaseEscrow.sol | head -10
# Need to verify these exist and match across all contracts
```

**What We Need**:
```solidity
// ✅ GOOD: Clear, batching-friendly
interface IEscrowQuery {
  function getWorkflowState(uint256 id) external view returns (uint8);
  function getUserBalance(address user) external view returns (uint256);
  function isPaused() external view returns (bool);
  function getVersion() external view returns (string memory);
}

// ❌ BAD: Inconsistent, can't batch reliably
function getInfo() external returns (bytes); // Returns data
function stateOf(uint256) external view returns (uint256, address, uint256); // Multiple fields
```

**Action Required**:
1. Audit all view functions in BaseEscrow
2. Ensure consistent naming (getX not stateX or infoX)
3. Each view returns single clear value
4. Add to IMultiCall interface
5. Test with multicall

**Timeline**: Should be done BEFORE mainnet (or in first patch)

---

### 1.3 Upgrade Path: Proxy Pattern

**Problem**: If we need to change logic later, we can't retrofit without redeployment.

**Current Status**:
- Need to check if using UUPSProxy or TransparentProxy
- If not using proxies: much harder to upgrade on L2s

**Action Required**:
```solidity
// If not already in place:
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract BaseEscrow is 
  Initializable,
  UUPSUpgradeable,
  // ... other interfaces
{
  // ✅ Enables future upgrades across all L2s
}
```

**Timeline**: CRITICAL - Do before or immediately after mainnet launch

---

## Part 2: Data & Storage Prerequisites

### 2.1 L2 Address Registry Setup

**Problem**: After deploying to multiple L2s, we lose track of addresses.

**Solution**: Deploy L2AddressRegistry on Ethereum immediately after mainnet launch.

```solidity
// Deploy immediately after mainnet:
contract L2AddressRegistry {
  struct L2Deployment {
    uint256 chainId;
    address baseEscrow;
    address vault;
    address governor;
    address registry;
    address timelock;
  }
  
  mapping(uint256 => L2Deployment) public deployments;
}
```

**Current Status**: 
- ❌ Does NOT exist yet
- Can be deployed later, but should be ready ASAP

**Action Required**:
1. Create `contracts/registry/L2AddressRegistry.sol`
2. Deploy on Ethereum mainnet (right after initial deployment)
3. Register initial deployments immediately
4. Add governance proposal requirement for new L2s

**Timeline**: Deploy to Ethereum immediately after mainnet (within 1 week)

---

### 2.2 Event Standardization

**Problem**: Off-chain monitoring needs consistent events across L2s.

**Current Status**:
- Need to check event signatures in BaseEscrow
- Events should be identical on all L2s

**Checklist**:
- [ ] WorkflowCreated(indexed uint256 id, indexed address sender, ...)
- [ ] WorkflowSettled(indexed uint256 id, indexed address recipient, ...)
- [ ] SystemPaused(indexed address guardian, string reason)
- [ ] SystemUnpaused(indexed address timelock)
- [ ] RecoveryProposed(indexed uint256 proposalId, ...)
- [ ] RecoveryExecuted(indexed uint256 proposalId, uint256 chainId)

**Action Required**:
1. Standardize event signatures
2. Ensure emitted on all operations
3. Add to monitoring scripts
4. Document event schema

**Timeline**: Before mainnet or in first patch

---

## Part 3: Infrastructure Prerequisites

### 3.1 RPC Endpoint Setup

**Action Required** (before multi-L2 launch):

```typescript
// scripts/config/rpc-config.ts
export const RPC_ENDPOINTS = {
  1: {
    name: 'Ethereum',
    urls: [
      process.env.RPC_ETHEREUM,
      'https://eth.merkle.io', // fallback
    ],
    maxBatchSize: 100,
  },
  8453: {
    name: 'Base',
    urls: [
      process.env.RPC_BASE,
      'https://base.merkle.io', // fallback
    ],
    maxBatchSize: 100,
  },
  42161: {
    name: 'Arbitrum',
    urls: [
      process.env.RPC_ARBITRUM,
      'https://arb1.merkle.io', // fallback
    ],
    maxBatchSize: 100,
  },
  10: {
    name: 'Optimism',
    urls: [
      process.env.RPC_OPTIMISM,
      'https://optimism.merkle.io', // fallback
    ],
    maxBatchSize: 100,
  },
};
```

**Checklist**:
- [ ] Primary RPC for each chain
- [ ] Fallback RPC for reliability
- [ ] Rate limits configured
- [ ] Batch size limits set
- [ ] Health check endpoints

**Timeline**: Ready before Phase 1 (balance aggregator)

---

### 3.2 Monitoring Infrastructure

**Action Required**:

```typescript
// scripts/monitoring/rpc-health-check.ts
export class RpcHealthMonitor {
  async checkHealth(chainId: number): Promise<boolean> {
    // ✅ Periodically check all RPCs
    // ✅ Alert if any go down
    // ✅ Switch to fallback automatically
  }
}
```

**Checklist**:
- [ ] Health check every 30 seconds
- [ ] Fallback if primary fails
- [ ] Alert on chain unavailability
- [ ] Log RPC performance metrics
- [ ] Track response times per chain

**Timeline**: Deploy before Phase 2 (smart routing)

---

## Part 4: Testing Prerequisites

### 4.1 Multi-Chain Test Infrastructure

**Current Status**:
- Tests probably run on single chain
- Need multi-chain test setup

**Action Required**:

```typescript
// test/foundry/multi-chain/setup.ts
export abstract class MultiChainTest {
  protected chainConfigs = [
    { chainId: 1, name: 'Ethereum' },
    { chainId: 8453, name: 'Base' },
    { chainId: 42161, name: 'Arbitrum' },
  ];
  
  async deployOnAllChains() {
    // Deploy same contract on all chains
    // Verify same address on all chains
    // Run tests in parallel
  }
}
```

**Checklist**:
- [ ] Test factory deploys to multiple chains
- [ ] Verify addresses match on all chains
- [ ] Run same test suite on each chain
- [ ] Test cross-chain scenarios
- [ ] Test RPC fallback behavior

**Timeline**: Build alongside Phase 1

---

### 4.2 Cross-Chain Scenario Tests

**Action Required**:

```typescript
// Test scenarios:
// 1. Query balance on all chains simultaneously
// 2. Route operation to optimal chain
// 3. Execute on one chain, verify on all
// 4. Simulate L2 outage, use fallback
// 5. Test replay protection across chains
```

**Timeline**: Before Phase 3 (account abstraction)

---

## Part 5: Deployment Prerequisites

### 5.1 Deployment Script Preparation

**Current Status**:
- Scripts probably deploy to single chain
- Need multi-chain deployment scripts

**Action Required**:

```bash
# scripts/deploy-to-all-chains.sh
#!/bin/bash

CHAINS=(ethereum base arbitrum optimism)
SALT="0x..." # Deterministic salt for CREATE2

for CHAIN in "${CHAINS[@]}"; do
  echo "Deploying to $CHAIN..."
  npx hardhat run scripts/deploy.ts --network $CHAIN --salt $SALT
done

echo "Registering deployments in L2AddressRegistry..."
npx hardhat run scripts/register-deployments.ts --network ethereum
```

**Checklist**:
- [ ] Same deployment script for all chains
- [ ] Deterministic salt used
- [ ] Addresses verified to match
- [ ] Registry updated after each chain
- [ ] Can rollback if needed

**Timeline**: Ready before Phase 1 launch

---

### 5.2 Address Management

**Current Status**:
- Probably storing addresses in hardhat deployments
- Need centralized registry

**Action Required**:

```typescript
// scripts/_lib/addresses.ts
export interface ChainDeployment {
  chainId: number;
  chainName: string;
  baseEscrow: string;
  vault: string;
  governor: string;
  moduleRegistry: string;
  timelock: string;
  multicall: string;
  salt: string;
  deploymentBlock: number;
  deploymentTx: string;
}

export const DEPLOYMENTS: Record<number, ChainDeployment> = {
  1: { /* Ethereum */ },
  8453: { /* Base */ },
  42161: { /* Arbitrum */ },
  10: { /* Optimism */ },
};
```

**Checklist**:
- [ ] Central address registry
- [ ] Addresses match across chains
- [ ] Includes deployment metadata
- [ ] Verify before using in scripts
- [ ] Regular audit

**Timeline**: Create before Phase 1

---

## Part 6: Governance Prerequisites

### 6.1 L2 Registration Governance

**Action Required**:

```solidity
// In Governor or Timelock:
// Proposal to add new L2:
// 1. Verify contract addresses
// 2. Verify same bytecode on all chains
// 3. Register in L2AddressRegistry
// 4. Enable on monitoring service
```

**Checklist**:
- [ ] Governance procedure for adding L2
- [ ] Verification requirements
- [ ] Quorum for multi-L2 decisions
- [ ] Timelock delay
- [ ] Reversal procedure if needed

**Timeline**: Define before Phase 2

---

## Part 7: Communication Prerequisites

### 7.1 Documentation

**Action Required**:

- [ ] Document deterministic deployment process
- [ ] Document address consistency checks
- [ ] Document RPC failover procedure
- [ ] Document monitoring alerts
- [ ] Document escalation procedures

**Timeline**: Before Phase 1 launch

---

## Part 8: Security Prerequisites

### 8.1 Address Validation

**Action Required**:

```typescript
// Before any multi-chain operation:
async function validateAddressConsistency(): Promise<boolean> {
  const addresses = getAddresses();
  
  for (const [chainId, deployment] of Object.entries(addresses)) {
    // 1. Verify contract exists at address
    const code = await getCode(deployment.baseEscrow, chainId);
    if (code === '0x') throw new Error(`No code at ${deployment.baseEscrow}`);
    
    // 2. Verify bytecode matches
    const hash = keccak256(code);
    if (hash !== expectedHash) throw new Error(`Bytecode mismatch on ${chainId}`);
    
    // 3. Verify address matches expected
    if (deployment.baseEscrow !== expectedAddress) {
      throw new Error(`Address mismatch on ${chainId}`);
    }
  }
  
  return true;
}
```

**Timeline**: Build into deployment script

---

## Part 9: Priority Implementation Matrix

| Prerequisite | Priority | Effort | Timeline | Impact |
|--------------|----------|--------|----------|--------|
| CREATE2 Factories | **CRITICAL** | 8h | Before mainnet | Blocks all future work |
| Address Registry | **HIGH** | 12h | Week 1 after launch | Enables monitoring |
| View Functions | **HIGH** | 6h | Before or after | Enables multicall |
| Upgrade Proxies | **HIGH** | 12h | Before mainnet | Enables updates |
| RPC Config | **MEDIUM** | 4h | Before Phase 1 | Enables balance view |
| Event Standardization | **MEDIUM** | 4h | Before mainnet | Enables monitoring |
| Multi-chain Tests | **MEDIUM** | 20h | Before Phase 3 | Ensures reliability |
| Deployment Scripts | **MEDIUM** | 8h | Before Phase 1 | Enables multi-L2 |
| Health Monitoring | **LOW** | 8h | Before Phase 2 | Improves reliability |

---

## Part 10: Recommended Implementation Order

### Phase 0: Before Mainnet (NOW)

```
Week 1:
  ✅ Create CREATE2 factories for all contracts
  ✅ Standardize view function signatures
  ✅ Add UUPS proxies if not present
  ✅ Set deployment salt constant

Week 2:
  ✅ Create L2AddressRegistry contract
  ✅ Create multi-chain deployment scripts
  ✅ Create address validation tests
  ✅ Document deployment procedures
```

**Effort**: ~60 hours
**Blockers**: None - can be done in parallel with current work
**Timeline**: Can be completed before mainnet launch

### Phase 0.5: Immediately After Mainnet (Week 1)

```
Day 1-2:
  ✅ Deploy L2AddressRegistry to Ethereum
  ✅ Register initial Ethereum deployment
  ✅ Set up RPC health monitoring
  ✅ Configure alerting

Day 3-5:
  ✅ Deploy to first additional L2 (Base)
  ✅ Verify deterministic address matching
  ✅ Register in L2AddressRegistry
  ✅ Test cross-L2 query
```

**Effort**: ~20 hours
**Timeline**: 1 week after mainnet

### Phase 1: Foundation (Then proceed with planned phases)

Now Phase 1 can use the solid foundation to build balance aggregator, etc.

---

## Part 11: Checklist for Review

### Before Mainnet
- [ ] CREATE2 factories implemented for all contracts
- [ ] All contracts use same salt for deterministic deployment
- [ ] View functions standardized and batching-friendly
- [ ] UUPS proxies added to main contracts
- [ ] Deployment scripts support multi-chain
- [ ] Address registry contract created
- [ ] Events standardized across all contracts
- [ ] Tests include multi-chain scenarios

### Immediately After Mainnet
- [ ] L2AddressRegistry deployed to Ethereum
- [ ] Initial deployments registered
- [ ] RPC endpoints configured for all chains
- [ ] Health monitoring active
- [ ] Deployment procedures documented
- [ ] Team trained on procedures

### Before Phase 1 (Balance Aggregator)
- [ ] All RPC configurations complete
- [ ] Address consistency verified
- [ ] Monitoring alerts working
- [ ] Fallback RPCs tested
- [ ] Multi-chain test infrastructure ready

### Before Phase 2 (Smart Routing)
- [ ] Gas price feeds available on all L2s
- [ ] Cross-L2 scenarios tested
- [ ] Route optimization verified
- [ ] Cost calculations accurate

### Before Phase 3 (Account Abstraction)
- [ ] EntryPoints identified/deployed
- [ ] Bundler endpoints available
- [ ] Account factory tested
- [ ] CREATE2 addresses verified
- [ ] Cross-L2 UserOp tests passing

---

## Part 12: Risks if NOT Done

| If We DON'T Do | Risk | Impact | Recovery |
|----------------|------|--------|----------|
| CREATE2 factories | Contracts at different addresses on each L2 | Can't build multi-L2 UX (addresses diverge) | **IMPOSSIBLE** - must migrate (expensive) |
| Address registry | Can't track where contracts are | Monitoring fails, manual management | Expensive migration, downtime |
| View standardization | Multicall batching doesn't work reliably | Can't build balance view efficiently | Refactor contracts (risky) |
| Proxy pattern | Can't upgrade on L2s | Bug fixes require redeployment | Complex workarounds, reputation damage |
| Event standardization | Off-chain monitoring broken | Manual status tracking required | Add events later (confusing) |
| RPC setup | Single point of failure | L2 outage = total UX failure | Add fallbacks later (patch) |

---

## Part 13: Questions & Decisions

### Q: Can we retrofit CREATE2 later?
**A**: Extremely difficult. Contracts already deployed won't use new factory. Either:
- Migrate all users (expensive, risky)
- Run parallel system (confusing, expensive)
- Can't add new L2s reliably

**Decision needed**: Implement before mainnet

### Q: Can we add proxy pattern later?
**A**: Yes, but risky. Would need to:
- Deploy new proxies
- Migrate state
- Redirect traffic
- Risk during migration

**Decision needed**: Implement before mainnet

### Q: Can we add address registry after launch?
**A**: Yes, completely safe. Deploy whenever.

**Decision needed**: Deploy in first week after launch

### Q: Do we need all RPC endpoints immediately?
**A**: Not for single-L2 launch, but needed before:
- Balance aggregator (Phase 1)
- Smart routing (Phase 2)

**Decision needed**: Prepare specs now, deploy before Phase 1

---

## Summary: What Must Be Done

### 🚨 CRITICAL (Do Before Mainnet)
1. CREATE2 factories for deterministic deployment
2. UUPS proxy pattern on main contracts
3. Standardized view functions
4. Multi-chain deployment scripts

### ⚠️ IMPORTANT (Do Within Week 1)
5. L2 Address Registry on Ethereum
6. RPC endpoint configuration
7. Deployment verification procedures
8. Event standardization

### 💡 NICE TO HAVE (Before Phase 1)
9. Health monitoring for RPCs
10. Multi-chain test infrastructure
11. Address validation automation

---

**Created**: Feb 4, 2026  
**Status**: Prerequisites Analysis Complete  
**Next**: Implementation decision meeting
