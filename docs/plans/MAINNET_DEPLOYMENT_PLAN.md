# Mainnet Deployment Plan for Coinstore IEO

## Executive Summary

This document outlines the deployment plan for production contracts to mainnet, required by Coinstore for their Initial Exchange Offering (IEO). The deployment will use the hardhat-deploy-hybrid infrastructure with support for upgradeable contracts (Transparent or UUPS proxy patterns).

## Current State Analysis

### Repository Structure

- **Deployment System**: Classic hardhat-deploy (not Ignition)
- **Proxy Support**: Both Transparent and UUPS via `PROXY_KIND` environment variable
- **Test Framework**: Hybrid (Hardhat TS tests + Foundry tests)
- **Deployment Ledger**: Timestamped deployment tracking in `deploy-ledger/<network>/<stamp>/`
- **Safety Checks**: Mainnet deployment requires `DEPLOY_CONFIRM=YES`

### Current Deployment Scripts

- `deploy/00_impl.ts` - Deploys implementation contract (UpgradeableBox example)
- `deploy/10_proxy.ts` - Deploys proxy with initialization
- `deploy/90_post.ts` - Post-deployment sanity checks

### Production Contracts to Deploy

#### Core Contracts

1. **EscrowableERC20**
   - Constructor: `(string name, string symbol, uint256 escrowFee, address escrowFeeAddress)`
   - Initial Supply: 1,000,000 tokens (18 decimals)
   - Inherits: ERC20, BaseEscrow
   - Upgradeable: Yes (recommended)

2. **EscrowVault**
   - Constructor: `(uint256 escrowFee, address escrowFeeAddress)`
   - Multi-token escrow vault
   - Inherits: BaseEscrow
   - Upgradeable: Yes (recommended)

#### Libraries (Deploy First - Required for Linking)

1. `EscrowEncodingLibrary`
2. `ResolverLogicLibrary`
3. `SettingsValidationLibrary`
4. `YieldDistributionLibrary`

#### Modules (Deploy Before Main Contracts)

1. **DefaultReleaseStrategy**
   - Constructor: `(address initialOwner)`

2. **DefaultResolutionModule**
   - Constructor: `(address initialOwner, address initialResolver)`

3. **AaveYieldGenerationModule** (if yield generation needed)
   - Constructor: `(address initialOwner)`
   - Requires: Aave Pool address configuration

4. **DefaultYieldDistributionModule**
   - Constructor: `(address initialOwner)`

5. **DecentralizedResolutionModule** (in separate package, optional for advanced dispute resolution)
   - Constructor: `(address initialOwner)`
   - Note: Can be swapped in via slow-lane governance once proven through testing

## Deployment Plan

### Phase 1: Pre-Deployment Preparation

#### 1.1 Environment Configuration

- [ ] Set up `.env` file with:
  - `PRIVATE_KEY` - Deployer private key
  - `RPC_BASE_MAINNET` or `RPC_ETHEREUM` - Mainnet RPC endpoint
  - `BASESCAN_API_KEY` or `ETHERSCAN_API_KEY` - For contract verification
  - `DEPLOY_CONFIRM=YES` - Required for mainnet deployment
  - `PROXY_KIND=transparent` or `PROXY_KIND=uups` - Choose proxy type

#### 1.2 Contract Parameters Decision

- [ ] **EscrowableERC20 Parameters**:
  - Token Name: [TO BE DECIDED]
  - Token Symbol: [TO BE DECIDED]
  - Escrow Fee: [TO BE DECIDED] (basis points, max 10000 = 100%)
  - Escrow Fee Address: [TO BE DECIDED] (multisig/Safe recommended)

- [ ] **EscrowVault Parameters**:
  - Escrow Fee: [TO BE DECIDED] (should match EscrowableERC20)
  - Escrow Fee Address: [TO BE DECIDED] (should match EscrowableERC20)

- [ ] **Module Parameters**:
  - Default Resolver Address: [TO BE DECIDED]
  - Aave Pool Address (if using yield): [TO BE DECIDED]

#### 1.3 Network Selection

- [ ] Choose deployment network:
  - Base Mainnet (Chain ID: 8453) - Recommended for lower gas costs
  - Ethereum Mainnet (Chain ID: 1) - Higher gas costs but more established

### Phase 2: Deployment Scripts Creation

#### 2.1 Library Deployment (`deploy/01_libraries.ts`)

```typescript
// Deploy all libraries first
// Libraries: EscrowEncodingLibrary, ResolverLogicLibrary,
//            SettingsValidationLibrary, YieldDistributionLibrary
// Tag: 'libraries'
```

#### 2.2 Module Deployment (`deploy/02_modules.ts`)

```typescript
// Deploy all modules
// Modules: DefaultReleaseStrategy, DefaultResolutionModule,
//          AaveYieldGenerationModule, DefaultYieldDistributionModule
// Tag: 'modules'
// Dependencies: ['libraries']
```

#### 2.3 Main Contract Implementation (`deploy/03_impl.ts`)

```typescript
// Deploy implementation contracts (no proxy yet)
// Contracts: EscrowableERC20_Impl, EscrowVault_Impl
// Tag: 'impl'
// Dependencies: ['libraries', 'modules']
```

#### 2.4 Proxy Deployment (`deploy/04_proxy.ts`)

```typescript
// Deploy proxies with initialization
// Contracts: EscrowableERC20 (via proxy), EscrowVault (via proxy)
// Tag: 'proxy'
// Dependencies: ['impl']
// Uses: PROXY_KIND environment variable
```

#### 2.5 Module Wiring (`deploy/05_wire_modules.ts`)

```typescript
// Wire modules to main contracts
// - Set defaultReleaseStrategy
// - Set defaultResolutionModule
// - Set defaultYieldGenerationModule (if applicable)
// - Set defaultYieldDistributionModule
// Tag: 'wire'
// Dependencies: ['proxy']
```

#### 2.6 Post-Deployment Verification (`deploy/06_verify.ts`)

```typescript
// Verify deployment state
// - Check contract addresses
// - Verify module connections
// - Test basic functionality
// - Verify token supply (for EscrowableERC20)
// Tag: 'verify'
// Dependencies: ['wire']
```

### Phase 3: Deployment Execution

#### 3.1 Test Deployment (Base Sepolia)

```bash
# Test on Base Sepolia first
pnpm deploy --network baseSepolia
pnpm export --network baseSepolia
```

#### 3.2 Mainnet Deployment

```bash
# Set environment variables
export DEPLOY_CONFIRM=YES
export PROXY_KIND=transparent  # or 'uups'
export RPC_BASE_MAINNET=<your-rpc-url>
export BASESCAN_API_KEY=<your-api-key>

# Deploy to mainnet
pnpm deploy --network base  # or 'ethereum' for Ethereum mainnet

# Export deployment ledger
pnpm export --network base

# Verify contracts on block explorer
pnpm verify --network base
```

### Phase 4: Post-Deployment

#### 4.1 Contract Verification

- [ ] Verify all contracts on Basescan/Etherscan
- [ ] Verify proxy implementations
- [ ] Verify library linking

#### 4.2 Governance Setup (Recommended)

- [ ] Transfer ownership to Safe multisig
- [ ] Set up Timelock for upgrades (if using UUPS)
- [ ] Configure authorized resolver
- [ ] Document admin addresses

#### 4.3 Documentation

- [ ] Document all deployed addresses
- [ ] Create deployment summary
- [ ] Update frontend configuration
- [ ] Share contract addresses with Coinstore

## Deployment Script Structure

### Recommended File Structure

```
deploy/
├── 01_libraries.ts      # Deploy libraries
├── 02_modules.ts         # Deploy modules
├── 03_impl.ts            # Deploy implementations
├── 04_proxy.ts           # Deploy proxies
├── 05_wire_modules.ts    # Wire modules to contracts
└── 06_verify.ts          # Post-deployment verification
```

### Tag Dependencies

- `libraries` → no dependencies
- `modules` → depends on `libraries`
- `impl` → depends on `libraries`, `modules`
- `proxy` → depends on `impl`
- `wire` → depends on `proxy`
- `verify` → depends on `wire`

## Safety Considerations

### Mainnet Deployment Safety

1. **Required Confirmation**: `DEPLOY_CONFIRM=YES` must be set
2. **Proxy Type**: Choose Transparent (safer) or UUPS (gas efficient)
3. **Ownership**: Never leave upgrade authority on EOA
4. **Verification**: Verify all contracts immediately after deployment
5. **Testing**: Always test on testnet first (Base Sepolia)

### Upgrade Safety

- Gate upgrades behind Safe + Timelock
- Require storage layout checks on every upgrade
- Never leave upgrade authority on an EOA
- Test upgrades on testnet before mainnet

## Deployment Ledger

The deployment ledger will be exported to:

```
deploy-ledger/<network>/<timestamp>/
├── meta.json              # Deployment metadata
├── addresses.json         # All contract addresses
├── abi/                   # ABI snapshots
└── hardhat-deploy.json    # Full deployment snapshot
```

## IEO-Specific Requirements

### Coinstore Requirements

- [ ] Mainnet contracts deployed before IEO date
- [ ] Contract addresses provided to Coinstore
- [ ] Verified contracts on block explorer
- [ ] Token contract (EscrowableERC20) fully functional
- [ ] Escrow functionality operational

### Recommended Timeline

1. **Week 1**: Create deployment scripts, test on Base Sepolia
2. **Week 2**: Finalize contract parameters, security review
3. **Week 3**: Deploy to mainnet, verify contracts
4. **Week 4**: Governance setup, documentation, handover to Coinstore

## Next Steps

1. **Immediate**: Create deployment scripts for all contracts
2. **Short-term**: Test deployment on Base Sepolia
3. **Medium-term**: Finalize contract parameters with stakeholders
4. **Long-term**: Deploy to mainnet and set up governance

## Notes

- The current deployment scripts only deploy `UpgradeableBox` as an example
- Production deployment scripts need to be created for actual contracts
- The export-ledger script needs to be updated to support all production contracts
- Consider using Transparent proxy for initial deployment (safer), can upgrade to UUPS later if needed
