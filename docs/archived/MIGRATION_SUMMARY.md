# Migration Summary: Testing Strategy & Cursor Settings

## Quick Answers

### 1. Testing Migration: Foundry vs Hardhat?

**Recommendation**: **Hybrid Approach** ✅

- **Foundry**: Core contract tests (invariants, fuzzing, gas optimization)
- **Hardhat**: Integration tests, deployment scripts, frontend integration

**Why Hybrid?**
- Foundry excels at property-based testing, fuzzing, and gas optimization
- Hardhat better for TypeScript integration, deployment, and complex test logic
- Both can run simultaneously in the new directory

**See**: `docs/TESTING_MIGRATION_STRATEGY.md` for detailed plan

---

### 2. Cursor Settings Migration?

**Yes, you can migrate** ✅

**What to migrate**:
- ✅ `.cursor/rules/scaffold-eth.mdc` (project rules)
- ✅ `.vscode/settings.json` (if exists)
- ✅ `.vscode/extensions.json` (if exists)

**What NOT to migrate**:
- ❌ `.cursor/index/` (index cache - will rebuild automatically)
- ❌ `.cursor/cache/` (general cache - will rebuild)

**See**: `docs/CURSOR_MIGRATION_GUIDE.md` for step-by-step instructions

---

## Current State

### Found Cursor Files
- ✅ `.cursor/rules/scaffold-eth.mdc` - Project rules file
- ⚠️ Needs update: References `yarn` (should be `pnpm` for new directory)
- ⚠️ Needs update: Add Foundry testing references

### Current Test Setup
- **Framework**: Hardhat with TypeScript
- **Test Files**: 
  - `BaseEscrow.test.ts`
  - `EscrowVault.test.ts`
  - `EscrowableERC20.ts`
  - `AaveIntegration.test.ts`
- **Coverage**: ~40-50% (estimated)

---

## Action Items

### Immediate (Before Migration)

1. **Review Testing Strategy** 📋
   - Read `docs/TESTING_MIGRATION_STRATEGY.md`
   - Decide on hybrid approach (recommended)
   - Plan Foundry test structure

2. **Prepare Cursor Rules Update** 📋
   - Current file: `.cursor/rules/scaffold-eth.mdc`
   - Update: `yarn` → `pnpm`
   - Add: Foundry testing references
   - Add: Hybrid testing approach documentation

### During Migration

1. **Copy Cursor Rules** 📋
   ```bash
   # From old directory
   cp .cursor/rules/scaffold-eth.mdc /path/to/new/directory/.cursor/rules/
   ```

2. **Update Rules File** 📋
   - Change package manager references
   - Add Foundry commands
   - Update testing guidelines

3. **Set Up Foundry Tests** 📋
   - Create `test/foundry/` directory
   - Write first invariant test
   - Configure `foundry.toml`

### After Migration

1. **Verify Cursor** ✅
   - Reopen Cursor in new directory
   - Verify rules are loaded
   - Let indexes rebuild automatically

2. **Start Foundry Testing** ✅
   - Write BaseEscrow invariants
   - Add fuzzing tests
   - Set up gas benchmarks

---

## Quick Migration Commands

### Copy Cursor Rules
```bash
# Create directory in new project
mkdir -p /path/to/new/directory/.cursor/rules

# Copy rules file
cp /home/user/Code/scaffold-eth-2/starter-scaffold-eth/.cursor/rules/scaffold-eth.mdc \
   /path/to/new/directory/.cursor/rules/scaffold-eth.mdc
```

### Update Rules File (Manual)
Edit the copied file and update:
- Line 9: `yarn monorepo` → `pnpm monorepo`
- Line 18-20: `yarn chain/deploy/start` → `pnpm chain/deploy/start`
- Add Foundry testing section

---

## Updated Cursor Rules Template

Here's an updated version of the cursor rules for the new directory:

```markdown
---
description: 
globs: 
alwaysApply: true
---

This codebase contains Scaffold-ETH 2 (SE-2), everything you need to build dApps on Ethereum. 
Its tech stack is NextJS, RainbowKit, Wagmi and Typescript. Supports Hardhat and Foundry.

It's a pnpm monorepo that contains following packages:

- HARDHAT (`packages/hardhat`): The solidity framework to write, test and deploy EVM Smart Contracts.
- NextJS (`packages/nextjs`): The UI framework extended with utilities to make interacting with Smart Contracts easy (using Next.js App Router, not Pages Router).

## Testing Framework

This project uses a hybrid testing approach:
- **Foundry**: For invariant testing, fuzzing, and gas optimization
  - Tests located in `packages/hardhat/test/foundry/`
  - Run with: `forge test` or `pnpm test:foundry`
- **Hardhat**: For integration tests and deployment scripts
  - Tests located in `packages/hardhat/test/`
  - Run with: `pnpm test` or `hardhat test`

The usual dev flow is:

- Start SE-2 locally:
  - `pnpm chain`: Starts a local blockchain network
  - `pnpm deploy`: Deploys SE-2 default contract
  - `pnpm start`: Starts the frontend
- Write a Smart Contract (modify the deployment script in `packages/hardhat/deploy` if needed)
- Deploy it locally (`pnpm deploy`)
- Test with Foundry (`forge test`) for invariants/fuzzing or Hardhat (`pnpm test`) for integration
- Go to the `http://localhost:3000/debug` page to interact with your contract with a nice UI
- Iterate until you get the functionality you want in your contract
- Write tests for the contract in `packages/hardhat/test` (Hardhat) or `packages/hardhat/test/foundry` (Foundry)
- Create your custom UI using all the SE-2 components, hooks, and utilities.
- Deploy your Smart Contract to a live network
- Deploy your UI (`pnpm vercel` or `pnpm ipfs`)
  - You can tweak which network the frontend is pointing (and some other configurations) in `scaffold.config.ts`

## Smart Contract UI interactions guidelines
SE-2 provides a set of hooks that facilitates contract interactions from the UI. It reads the contract data from `deployedContracts.ts` and `externalContracts.ts`, located in `packages/nextjs/contracts`.

### Reading data from a contract
Use the `useScaffoldReadContract` (`packages/nextjs/hooks/scaffold-eth/useScaffoldReadContract.ts`) hook. 

Example:
```typescript
const { data: someData } = useScaffoldReadContract({
  contractName: "YourContract",
  functionName: "functionName",
  args: [arg1, arg2], // optional
});
```

### Writing data to a contract
Use the `useScaffoldWriteContract` (`packages/nextjs/hooks/scaffold-eth/useScaffoldWriteContract.ts`) hook.
1. Initialize the hook with just the contract name
2. Call the `writeContractAsync` function.

Example:
```typescript
const { writeContractAsync: writeYourContractAsync } = useScaffoldWriteContract(
  { contractName: "YourContract" }
);
// Usage (this will send a write transaction to the contract)
await writeContractAsync({
  functionName: "functionName",
  args: [arg1, arg2], // optional
  value: parseEther("0.1"), // optional, for payable functions
});
```

Never use any other patterns for contract interaction. The hooks are:
- useScaffoldReadContract (for reading)
- useScaffoldWriteContract (for writing)

### Other Hooks
SE-2 also provides other hooks to interact with blockchain data: `useScaffoldWatchContractEvent`, `useScaffoldEventHistory`, `useDeployedContractInfo`, `useScaffoldContract`, `useTransactor`. They live under `packages/nextjs/hooks/scaffold-eth`.

## Display Components guidelines
SE-2 provides a set of pre-built React components for common Ethereum use cases: 
- `Address`: Always use this when displaying an ETH address
- `AddressInput`: Always use this when users need to input an ETH address
- `Balance`: Display the ETH/USDC balance of a given address
- `EtherInput`: An extended number input with ETH/USD conversion.

They live under `packages/nextjs/components/scaffold-eth`.

Find the relevant information from the documentation and the codebase. Think step by step before answering the question.
```

---

## Next Steps

1. ✅ **Read detailed guides**:
   - `docs/TESTING_MIGRATION_STRATEGY.md` - Testing strategy
   - `docs/CURSOR_MIGRATION_GUIDE.md` - Cursor migration steps

2. ✅ **Copy cursor rules** to new directory

3. ✅ **Update rules file** with pnpm and Foundry references

4. ✅ **Set up Foundry** in new directory

5. ✅ **Start writing Foundry tests** for core contracts

---

**Last Updated**: Current Date

