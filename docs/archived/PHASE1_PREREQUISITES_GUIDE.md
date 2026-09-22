# Phase 1: Prerequisites Implementation Guide

**Status**: Implementation Started  
**Duration**: ~20 hours  
**Timeline**: Must complete before mainnet launch  

## Overview

Phase 1 implements the critical infrastructure that enables multi-L2 support. This guide covers:

1. **CREATE2 Factories** - Deterministic deployment across L2s
2. **Multicall-Optimized Views** - Efficient balance aggregation
3. **Testing & Validation** - Testnet verification
4. **Documentation** - Deployment procedures

## Section 1: CREATE2 Factory (8 hours)

### What It Does

```solidity
CREATE2EscrowFactory factory = new CREATE2EscrowFactory();
bytes32 salt = keccak256("mainnet-vault-v1");

// Ethereum
address ethereumVault = factory.deployEscrow(
    escrowFeeBps, feeAddress, yieldOps, disputeOps, moduleMgmt, salt
); // deployed to 0x1234...

// Base (same salt, same args)
address baseVault = factory.deployEscrow(
    escrowFeeBps, feeAddress, yieldOps, disputeOps, moduleMgmt, salt
); // deployed to 0x1234... (SAME ADDRESS!)

// Arbitrum
address arbitrumVault = factory.deployEscrow(
    escrowFeeBps, feeAddress, yieldOps, disputeOps, moduleMgmt, salt
); // deployed to 0x1234... (SAME ADDRESS!)
```

**Key Benefit**: Same contract address on all L2s = simpler routing + cheaper RPC costs

### Implementation Details

**File**: `contracts/core/CREATE2EscrowFactory.sol`

```solidity
contract CREATE2EscrowFactory {
    // Address prediction (no gas, no deployment)
    function getDeploymentAddress(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress,
        bytes32 salt
    ) external view returns (address predictedAddress);

    // Actual deployment
    function deployEscrow(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress,
        bytes32 salt
    ) external returns (EscrowVault escrowVault);

    // Status check
    function isDeployed(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress,
        bytes32 salt
    ) external view returns (bool deployed);
}
```

### Deployment Workflow

#### Step 1: Pre-Deployment Verification (0.5h)

```bash
# Compile contracts
npx hardhat compile

# Verify no size issues
npx hardhat compile --show-stack-traces
```

**Expected Output**:
```
Compiled 5 Solidity files successfully
Successfully generated 116 typings!
```

#### Step 2: Deploy on Ethereum Mainnet (1h)

```bash
# Deploy factory
npx hardhat deploy --network mainnet --tags create2

# Verify deployment
npx hardhat verify --network mainnet 0x<factory-address>
```

**Store**:
- Factory address
- Deployment salt
- Constructor parameters

#### Step 3: Pre-Calculate L2 Addresses (1h)

```javascript
// Get predicted addresses for all L2s
const addresses = await factory.getDeploymentAddress(
    escrowFeeBps,
    feeAddress,
    yieldOps,
    disputeOps,
    moduleMgmt,
    salt
);

console.log(`Ethereum:  ${ethereumFactory.getDeploymentAddress(...)}`);
console.log(`Base:      ${baseFactory.getDeploymentAddress(...)}`);
console.log(`Arbitrum:  ${arbitrumFactory.getDeploymentAddress(...)}`);
console.log(`Optimism:  ${optimismFactory.getDeploymentAddress(...)}`);
```

**Expected**: All return same address ✅

#### Step 4: Deploy on L2s (2h)

```bash
# Base Sepolia
npx hardhat deploy --network base-sepolia --tags create2

# Arbitrum Sepolia
npx hardhat deploy --network arbitrum-sepolia --tags create2

# Optimism Sepolia
npx hardhat deploy --network optimism-sepolia --tags create2
```

#### Step 5: Verify Addresses Match (2h)

```typescript
// deployment/verify-addresses.ts
const contracts = [
  { chain: 'ethereum', address: ETHEREUM_VAULT },
  { chain: 'base', address: BASE_VAULT },
  { chain: 'arbitrum', address: ARBITRUM_VAULT },
  { chain: 'optimism', address: OPTIMISM_VAULT }
];

for (const contract of contracts) {
  const code = await ethers.provider.getCode(contract.address);
  if (code.length < 100) {
    console.error(`❌ ${contract.chain}: No code deployed`);
  } else {
    console.log(`✓ ${contract.chain}: ${contract.address}`);
  }
}
```

**Expected Output**:
```
✓ ethereum:  0x1234... (deployed)
✓ base:      0x1234... (same!)
✓ arbitrum:  0x1234... (same!)
✓ optimism:  0x1234... (same!)
```

#### Step 6: Test Deployment (1.5h)

```bash
# Run factory tests
npx hardhat test test/Phase1_CREATE2Factory.t.ts

# Run integration tests
npx hardhat test test/Phase1_CREATE2Factory.integration.ts
```

## Section 2: Multicall View Aggregator (6 hours)

### What It Does

Provides fixed-size structs for efficient multicall batching:

```typescript
const multicall = new Multicall3(MULTICALL3_ADDRESS);

const calls = [
  {
    target: ETHEREUM_AGGREGATOR,
    callData: aggregator.interface.encodeFunctionData('getEscrowSnapshot', [0])
  },
  {
    target: BASE_AGGREGATOR,
    callData: aggregator.interface.encodeFunctionData('getEscrowSnapshot', [0])
  },
  {
    target: ARBITRUM_AGGREGATOR,
    callData: aggregator.interface.encodeFunctionData('getEscrowSnapshot', [0])
  }
];

// Single RPC call to get data from all 3 L2s!
const results = await multicall.aggregate3(calls);
```

### Implementation Details

**File**: `contracts/core/MultiL2ViewAggregator.sol`

Fixed-size structs:

```solidity
struct EscrowSnapshot {
    address token;
    address from;
    address to;
    address resolver;
    uint256 amount;
    uint64 autoReleaseTime;
    uint64 autoCancelTime;
    uint8 state;  // EscrowState as uint8
}

struct SettingsSnapshot {
    address customResolver;
    uint8 yieldPreset;
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
}
```

### Deployment Workflow

#### Step 1: Deploy Aggregator (1h)

```bash
# Deploy to all chains (requires EscrowVault already deployed)
npx hardhat deploy --network ethereum --tags create2
npx hardhat deploy --network base --tags create2
npx hardhat deploy --network arbitrum --tags create2
npx hardhat deploy --network optimism --tags create2
```

#### Step 2: Test Multicall (2h)

```bash
npx hardhat test test/Phase1_MultiL2ViewAggregator.t.ts
```

**Expected Output**:
```
✓ Snapshot Functions (3 passing)
✓ Health Checks (4 passing)
✓ Batch Operations (3 passing)
✓ Multicall Compatibility (3 passing)
✓ Cross-L2 View Consistency (2 passing)
```

#### Step 3: Integrate with Frontend (2h)

```typescript
// lib/multicall-aggregator.ts
export class MultiL2Aggregator {
  constructor(private multicall: Multicall3) {}

  async getBalancesAcrossL2s(escrowIds: number[]) {
    const calls = [];

    for (const chainId of [1, 8453, 42161, 10]) {
      const aggregatorAddress = AGGREGATOR_ADDRESSES[chainId];

      for (const escrowId of escrowIds) {
        calls.push({
          target: aggregatorAddress,
          callData: MultiL2ViewAggregator.interface.encodeFunctionData(
            'getEscrowSnapshot',
            [escrowId]
          ),
          chainId,
        });
      }
    }

    // Single RPC call to Multicall3
    const results = await this.multicall.aggregate3(calls);

    return this.parseResults(results);
  }
}
```

## Section 3: Testing & Validation (4 hours)

### Test Suite

**Unit Tests** (`test/Phase1_CREATE2Factory.t.ts`):
- ✓ Deterministic address computation
- ✓ Parameter change detection
- ✓ Salt-based versioning
- ✓ Deployment status tracking
- ✓ Multi-L2 scenarios

**Integration Tests** (`test/Phase1_MultiL2ViewAggregator.t.ts`):
- ✓ Snapshot function correctness
- ✓ Health check endpoints
- ✓ Batch operation support
- ✓ Multicall compatibility
- ✓ Cross-L2 consistency

### Testnet Checklist

- [ ] Deploy factory on Ethereum Sepolia
- [ ] Deploy factory on Base Sepolia
- [ ] Deploy factory on Arbitrum Sepolia
- [ ] Deploy factory on Optimism Sepolia
- [ ] Verify same addresses on all testnets
- [ ] Deploy aggregators
- [ ] Test multicall across all chains
- [ ] Verify no regressions in existing tests
- [ ] Document deployment addresses
- [ ] Create deployment runbook

### Validation Script

```typescript
// scripts/validate-phase1.ts
async function validatePhase1() {
  const chains = [
    { name: 'Ethereum', network: ethers.getDefaultProvider('mainnet') },
    { name: 'Base', network: ethers.getDefaultProvider('base') },
    { name: 'Arbitrum', network: ethers.getDefaultProvider('arbitrum') },
    { name: 'Optimism', network: ethers.getDefaultProvider('optimism') },
  ];

  const expectedAddress = '0x1234...'; // Your deployed address

  for (const chain of chains) {
    const code = await chain.network.getCode(expectedAddress);
    const matches = code.length > 100;
    console.log(`${chain.name}: ${matches ? '✓' : '✗'}`);
  }
}
```

## Section 4: Documentation (2 hours)

### Deployment Runbook

Create `docs/DEPLOYMENT_RUNBOOK_CREATE2.md`:

```markdown
# CREATE2 Deployment Runbook

## Pre-Deployment
1. [ ] Verify all constructor parameters
2. [ ] Test on testnets (all 4 L2s)
3. [ ] Get 3 signatures from deployment team
4. [ ] Backup seed phrase

## Ethereum Deployment
1. [ ] Deploy factory
2. [ ] Store factory address in registry
3. [ ] Verify on Etherscan

## L2 Deployments
1. [ ] Deploy on Base
2. [ ] Deploy on Arbitrum
3. [ ] Deploy on Optimism
4. [ ] Verify addresses match

## Post-Deployment
1. [ ] Update L2AddressRegistry
2. [ ] Test multicall across L2s
3. [ ] Notify team of new addresses
4. [ ] Monitor for issues
```

### Update Prerequisites Doc

Update `PREREQUISITES_FOR_MULTIL2.md`:

Add section: "## Phase 1 Completed"

```markdown
### ✅ CREATE2 Factory Deployed

- Ethereum:  0x1234...
- Base:      0x1234... (same!)
- Arbitrum:  0x1234... (same!)
- Optimism:  0x1234... (same!)

Deployment Date: [DATE]
Deployed By: [NAME]
Verification: All addresses match ✓
```

## Success Criteria

Phase 1 is complete when:

- [x] CREATE2EscrowFactory compiles without size errors
- [x] MultiL2ViewAggregator compiles without errors
- [x] All unit tests pass
- [x] All integration tests pass
- [x] No regressions in existing tests (328+ tests still passing)
- [ ] Factory deployed on Ethereum
- [ ] Factory deployed on all 4 L2s
- [ ] All deployments verified (same addresses)
- [ ] Multicall tested across all L2s
- [ ] Documentation complete
- [ ] Deployment runbook created
- [ ] Team trained on procedures

## Time Breakdown

| Task | Hours | Status |
|------|-------|--------|
| CREATE2 Factory (design + implementation) | 3 | ✓ Done |
| Multicall View Aggregator | 2 | ✓ Done |
| Unit & Integration Tests | 2 | ✓ Done |
| Deployment Script | 1 | ✓ Done |
| Ethereum Deployment | 2 | Pending |
| L2 Deployments (3 chains) | 3 | Pending |
| Testing & Validation | 2 | Pending |
| Documentation & Runbook | 2 | Pending |
| **Total** | **20** | **6 Done, 14 Pending** |

## Next Steps

1. **Deploy on Ethereum Sepolia** (testnet)
2. **Deploy on all L2 testnets**
3. **Verify addresses match**
4. **Test multicall across all chains**
5. **Complete Phase 2: L2AddressRegistry**

---

**Contact**: [DevOps/Deployment Lead]  
**Last Updated**: Feb 4, 2026  
**Version**: 1.0
