# Governance Process

Complete guide to the governance process: Forum → Vote → Timelock → Execute.

---

## Overview

The Sew Protocol uses onchain governance with the following flow:

1. **Forum Discussion** (offchain) - Discuss proposal
2. **Proposal Creation** (onchain) - Create proposal via Governor
3. **Voting Period** (onchain) - Token holders vote
4. **Queue to Timelock** (onchain) - Queue proposal after vote passes
5. **Timelock Delay** (onchain) - Wait for delay period
6. **Execution** (onchain) - Execute proposal

---

## Step 1: Forum Discussion

### Where to Discuss

- **Governance Forum**: [TBD - Add forum URL]
- **Discord**: [TBD - Add Discord channel]
- **Snapshot**: [TBD - Add Snapshot space] (for signaling)

### Proposal Template

```markdown
## Proposal Title

### Summary
Brief summary of the proposal.

### Motivation
Why is this change needed?

### Specification
Detailed specification of the changes.

### Governance Lane
- [ ] Emergency (Guardian only)
- [ ] Standard (48h delay)
- [ ] Slow (~9 days delay)

### Implementation
- Contract changes (if any)
- Parameter values
- Module addresses (if module swap)

### Testing
- Tests run
- Fork simulation results
- Risk assessment

### Timeline
- Proposal date
- Expected execution date
```

---

## Step 2: Build Proposal

### Using Governance Tooling

1. **Create Payload Builder**:
   ```typescript
   // governance/payloads/XXXX_description.ts
   export const metadata: ProposalMetadata = {
     id: "XXXX_description",
     title: "Proposal Title",
     description: "Full proposal description",
     lane: "standard", // or "slow" or "emergency"
     requiredContracts: ["ContractName"],
   };

   const buildPayload = async (hre, config) => {
     // Build proposal calls
     return calls;
   };
   ```

2. **Build Proposal Artifact**:
   ```bash
   pnpm gov:build governance/payloads/XXXX_description.ts
   ```

3. **Review Generated Artifact**:
   ```bash
   cat governance/proposals/XXXX_description.json
   ```

### Manual Proposal Building

If not using tooling, prepare:
- Target addresses
- Function names
- Calldata
- Values (if payable)

---

## Step 3: Create Onchain Proposal

### Prerequisites

1. **Proposal Threshold**: Must hold minimum tokens (e.g., 1% of supply)
2. **Voting Power**: Must have delegated voting power
3. **Network**: Deploy to target network (testnet first)

### Create Proposal

```typescript
// Via Hardhat console or script
const governor = await ethers.getContractAt('GovGovernor', governorAddress);

const targets = [contractAddress];
const values = [0];
const calldatas = [contract.interface.encodeFunctionData('functionName', [args])];
const description = "Proposal description";

const tx = await governor.propose(targets, values, calldatas, description);
const receipt = await tx.wait();

// Get proposal ID
const proposalId = await governor.hashProposal(targets, values, calldatas, ethers.id(description));
```

### Or Use Staging Tool

```bash
pnpm gov:stage governance/proposals/XXXX_description.json --stage=propose --network baseSepolia
```

---

## Step 4: Voting Period

### Voting Parameters

- **Voting Delay**: 1 block (for testing) or ~1 day (for mainnet)
- **Voting Period**: ~1 week (45818 blocks @ 13s/block)
- **Proposal Threshold**: 1% of supply (10M tokens)
- **Quorum**: 4% of supply (40M tokens)

### Cast Vote

```typescript
const governor = await ethers.getContractAt('GovGovernor', governorAddress);

// 0 = Against, 1 = For, 2 = Abstain
const support = 1; // For
const tx = await governor.castVote(proposalId, support);
await tx.wait();
```

### Check Vote Status

```typescript
const state = await governor.state(proposalId);
// 0 = Pending, 1 = Active, 2 = Canceled, 3 = Defeated, 4 = Succeeded, 5 = Queued, 6 = Expired, 7 = Executed

const hasVoted = await governor.hasVoted(proposalId, voterAddress);
const vote = await governor.getVotes(voterAddress, blockNumber);
```

---

## Step 5: Queue to Timelock

### After Vote Succeeds

Once proposal state is `Succeeded` (4):

```typescript
const governor = await ethers.getContractAt('GovGovernor', governorAddress);

const targets = [contractAddress];
const values = [0];
const calldatas = [contract.interface.encodeFunctionData('functionName', [args])];
const descriptionHash = ethers.id(description);

const tx = await governor.queue(targets, values, calldatas, descriptionHash);
await tx.wait();
```

### Or Use Staging Tool

```bash
pnpm gov:stage governance/proposals/XXXX_description.json --stage=queue --network baseSepolia
```

### Check Queue Status

```typescript
const state = await governor.state(proposalId);
// Should be 5 = Queued

// Get execution ETA from Timelock
const timelock = await ethers.getContractAt('TimelockController', timelockAddress);
const minDelay = await timelock.getMinDelay();
const eta = block.timestamp + minDelay; // For Standard lane
```

---

## Step 6: Wait for Delay

### Standard Lane (48h)

Wait 48 hours after queueing before execution is possible.

### Slow Lane (~9 days)

1. **Queue Phase**: Wait 48h after queue proposal
2. **Wait Phase**: Wait 7 days (enforced onchain)
3. **Activate Phase**: Wait 48h after activate proposal

### Check Execution Readiness

```typescript
const state = await governor.state(proposalId);
// 5 = Queued (ready for execution)

// For Slow lane, check ETA
const [value, eta, exists] = await contract.getPendingX();
if (block.timestamp >= eta && exists) {
  // Ready to activate
}
```

---

## Step 7: Execute Proposal

### Execute Standard Lane Proposal

```typescript
const governor = await ethers.getContractAt('GovGovernor', governorAddress);

const targets = [contractAddress];
const values = [0];
const calldatas = [contract.interface.encodeFunctionData('functionName', [args])];
const descriptionHash = ethers.id(description);

const tx = await governor.execute(targets, values, calldatas, descriptionHash);
await tx.wait();
```

### Execute Slow Lane Activation

```typescript
// First, activate the queued change
const contract = await ethers.getContractAt('ContractName', contractAddress);
const tx = await contract.activateX(); // e.g., activateEscrowFeeAddress()
await tx.wait();
```

### Or Use Staging Tool

```bash
pnpm gov:stage governance/proposals/XXXX_description.json --stage=execute --network baseSepolia
```

---

## Step 8: Verify Execution

### Check Proposal State

```typescript
const state = await governor.state(proposalId);
// Should be 7 = Executed
```

### Verify State Changes

```typescript
// Check that state variables were updated
const newValue = await contract.getX();
assert(newValue === expectedValue);
```

### Or Use Check Tool

```bash
pnpm gov:check governance/proposals/XXXX_description.json --network baseMainnet
```

---

## Proposal Templates

### Standard Lane Proposal

```markdown
## Set Token Cap for USDC

**Lane**: Standard (48h delay)

**Summary**: Set a cap of 10M USDC for Aave yield generation.

**Calls**:
- `AaveYieldGenerationModule.setTokenCap(USDC_ADDRESS, 10000000e6)`

**Testing**: Fork simulation passed.
```

### Slow Lane Proposal (Queue)

```markdown
## Queue New Escrow Fee Address

**Lane**: Slow (~9 days delay)

**Summary**: Queue a new address to receive escrow fees.

**Calls**:
- `EscrowableERC20.queueEscrowFeeAddress(NEW_FEE_ADDRESS)`
- `EscrowVault.queueEscrowFeeAddress(NEW_FEE_ADDRESS)`

**Next Step**: After 7 days, create activation proposal.
```

### Slow Lane Proposal (Activate)

```markdown
## Activate Queued Escrow Fee Address

**Lane**: Slow (activation phase)

**Summary**: Activate the previously queued escrow fee address.

**Calls**:
- `EscrowableERC20.activateEscrowFeeAddress()`
- `EscrowVault.activateEscrowFeeAddress()`

**Prerequisite**: Queue proposal executed 7+ days ago.
```

### Emergency Action

```markdown
## Emergency Pause Protocol

**Lane**: Emergency (0h delay)

**Summary**: Pause protocol due to [reason].

**Actions**:
- `EscrowableERC20.pause()` (Guardian)
- `EscrowVault.pause()` (Guardian)

**Reversal**: Unpause via Standard lane (48h delay, Timelock).
```

---

## Runbook Examples

### Example 1: Standard Parameter Change

1. Discuss on forum
2. Build proposal: `pnpm gov:build governance/payloads/0001_set_token_cap.ts`
3. Propose: `pnpm gov:stage governance/proposals/0001_set_token_cap.json --stage=propose`
4. Vote (wait for voting period)
5. Queue: `pnpm gov:stage governance/proposals/0001_set_token_cap.json --stage=queue`
6. Wait 48h
7. Execute: `pnpm gov:stage governance/proposals/0001_set_token_cap.json --stage=execute`
8. Verify: `pnpm gov:check governance/proposals/0001_set_token_cap.json`

### Example 2: Slow Lane Module Swap

1. Discuss on forum
2. Build queue proposal: `pnpm gov:build governance/payloads/0005_queue_resolution_module.ts`
3. Propose queue: `pnpm gov:stage governance/proposals/0005_queue_resolution_module.json --stage=propose`
4. Vote and queue (wait for voting period + 48h)
5. Wait 7 days
6. Build activate proposal: `pnpm gov:build governance/payloads/0006_activate_resolution_module.ts`
7. Propose activate: `pnpm gov:stage governance/proposals/0006_activate_resolution_module.json --stage=propose`
8. Vote and execute (wait for voting period + 48h)
9. Verify: `pnpm gov:check governance/proposals/0006_activate_resolution_module.json`

---

## Best Practices

1. **Test First**: Always test on testnet before mainnet
2. **Fork Simulation**: Run fork simulation before proposing
3. **Clear Communication**: Clearly communicate proposal intent
4. **Sufficient Time**: Allow sufficient time for review and voting
5. **Documentation**: Document all proposals and outcomes
6. **Verification**: Always verify execution after proposal passes

---

## References

- `governance.md` - Governance model
- `GOVERNANCE_SURFACE_MAP.md` - Function mapping
- `UPGRADE_POLICY.md` - Upgrade procedures
- `EMERGENCY_POLICY.md` - Emergency procedures
- `scripts/gov/` - Governance tooling





