# Account Abstraction for Multi-L2 Escrow

**Status**: Design Proposal for Phase 3  
**Last Updated**: Feb 4, 2026  
**Scope**: EIP-4337 UserOp patterns, cross-L2 intent execution

---

## Executive Summary

Account Abstraction (EIP-4337) enables:
1. **Batch Operations** - Execute multiple actions in single UserOp
2. **Cross-L2 Intents** - User signs once, executes on all L2s
3. **Sponsored Transactions** - Dapp/DAO pays gas for users
4. **Custom Logic** - Flexible authorization and validation

For multi-L2 escrow, AA enables:
- Single-click fund transfer across L2s
- Governance executing proposals on all L2s atomically
- Gasless operations for UX improvement

---

## Part 1: EntryPoint Deployment Strategy

### 1.1 Standard EntryPoint v0.6

**Networks**: Ethereum, Base, Arbitrum, Optimism, Polygon

```typescript
// Deployment config
const entryPointConfig = {
  ethereum: {
    address: '0x5FF137D4b0FDCD49DcA30c7B57b04b0541c8F434', // v0.6
    rpcUrl: process.env.RPC_ETHEREUM,
  },
  base: {
    address: '0x5FF137D4b0FDCD49DcA30c7B57b04b0541c8F434', // same address
    rpcUrl: process.env.RPC_BASE,
  },
  arbitrum: {
    address: '0x5FF137D4b0FDCD49DcA30c7B57b04b0541c8F434', // same address
    rpcUrl: process.env.RPC_ARBITRUM,
  },
  optimism: {
    address: '0x5FF137D4b0FDCD49DcA30c7B57b04b0541c8F434', // same address
    rpcUrl: process.env.RPC_OPTIMISM,
  },
};
```

**Advantage**: Same EntryPoint address on all chains (simpler routing)

### 1.2 Bundler Configuration

```typescript
interface BundlerConfig {
  chainId: number;
  rpcUrl: string;
  bundlerUrl: string;
  maxBatchSize: number;
  maxOpDataBytes: number;
}

const bundlers = [
  {
    chainId: 1,
    rpcUrl: process.env.RPC_ETHEREUM,
    bundlerUrl: 'https://bundler.example.com/ethereum',
    maxBatchSize: 100,
    maxOpDataBytes: 24576,
  },
  {
    chainId: 8453,
    rpcUrl: process.env.RPC_BASE,
    bundlerUrl: 'https://bundler.example.com/base',
    maxBatchSize: 100,
    maxOpDataBytes: 24576,
  },
  // ... more chains
];
```

---

## Part 2: Account Implementation

### 2.1 Deterministic Account Creation

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@account-abstraction/contracts/core/BaseAccount.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

/**
 * @title SimpleAccount
 * @dev Deterministic account usable across L2s with same address
 * 
 * Pattern: CREATE2 with same salt on all chains = same address
 */
contract SimpleAccount is BaseAccount, Ownable {
    address public entryPoint;
    
    constructor(address _entryPoint, address owner) {
        entryPoint = _entryPoint;
        transferOwnership(owner);
    }
    
    /**
     * Validate UserOp signature
     */
    function validateUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override returns (uint256) {
        // Verify signature from owner
        bytes memory signature = userOp.signature;
        
        bytes32 digest = toEthSignedMessageHash(userOpHash);
        address recovered = recoverAddress(digest, signature);
        
        require(recovered == owner(), "Invalid signature");
        
        // Return 0 for validation success
        return 0;
    }
    
    /**
     * Execute transaction from UserOp
     */
    function execute(address dest, uint256 value, bytes calldata func) public {
        require(msg.sender == address(entryPoint), "Only EntryPoint");
        (bool success, bytes memory result) = dest.call{value: value}(func);
        require(success, "Call failed");
    }
    
    /**
     * Batch execute multiple transactions
     */
    function executeBatch(
        address[] calldata dests,
        bytes[] calldata funcs
    ) public {
        require(msg.sender == address(entryPoint), "Only EntryPoint");
        require(dests.length == funcs.length, "Length mismatch");
        
        for (uint256 i = 0; i < dests.length; i++) {
            (bool success, bytes memory result) = dests[i].call(funcs[i]);
            require(success, "Batch call failed");
        }
    }
    
    // ... additional functions
}

/**
 * @title AccountFactory
 * @dev Creates accounts with deterministic addresses using CREATE2
 */
contract AccountFactory {
    event AccountCreated(address indexed account, address owner);
    
    function createAccount(address owner, uint256 salt) 
        external 
        returns (address) 
    {
        bytes32 _salt = keccak256(abi.encodePacked(owner, salt));
        bytes memory creationCode = type(SimpleAccount).creationCode;
        
        address account;
        assembly {
            account := create2(0, add(creationCode, 0x20), mload(creationCode), _salt)
        }
        
        emit AccountCreated(account, owner);
        return account;
    }
    
    /**
     * Get account address deterministically (no need to deploy)
     */
    function getAccountAddress(address owner, uint256 salt) 
        external 
        view 
        returns (address) 
    {
        bytes32 _salt = keccak256(abi.encodePacked(owner, salt));
        bytes memory creationCode = type(SimpleAccount).creationCode;
        
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), _salt, keccak256(creationCode))
        );
        
        return address(uint160(uint256(hash)));
    }
}
```

### 2.2 Paymaster for Sponsored Transactions

```solidity
/**
 * @title EscrowPaymaster
 * @dev Sponsors gas for escrow operations
 * 
 * Pattern: DAO/Dapp pre-funds paymaster to sponsor user gas
 */
contract EscrowPaymaster is BasePaymaster {
    mapping(address => uint256) public stakedAccounts;
    
    /**
     * Validate sponsorship request
     */
    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) external override returns (bytes memory context, uint256 validationData) {
        // Check if operation is escrow-related
        (address target, ) = parseCalldata(userOp.callData);
        require(isApprovedEscrowContract(target), "Not approved escrow");
        
        // Sponsor gas - return empty context
        return ("", 0);
    }
    
    /**
     * Post-execution: charge to staked account if operation succeeded
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost
    ) external override {
        if (mode == PostOpMode.postOpReverted) {
            return; // Don't charge if reverted
        }
        
        // Deduct from sponsor account
        // Implementation depends on how sponsor is identified
    }
}
```

---

## Part 3: Cross-L2 UserOp Coordination

### 3.1 Intent-Based Execution

```typescript
// scripts/aa/CrossL2IntentExecutor.ts

interface L2Intent {
  description: string;
  operations: {
    chainId: number;
    target: string;
    callData: string;
    value?: bigint;
  }[];
}

/**
 * User Intent: "Execute escrow settlement on all L2s where I have balance"
 * 
 * System:
 *   1. Query balances on all L2s
 *   2. Create UserOps for chains with balance
 *   3. Get single signature from user (covers all UserOps)
 *   4. Submit to bundlers in parallel
 *   5. Wait for completion on all chains
 */
class CrossL2IntentExecutor {
  /**
   * Execute intent with minimal user friction
   */
  async executeIntent(
    userAddress: string,
    intent: L2Intent,
    signer: any
  ): Promise<Map<number, string>> {
    // Step 1: Query balances
    const balances = await this.queryBalances(userAddress);
    
    // Step 2: Filter to active chains
    const activeChains = intent.operations.filter(op =>
      balances.has(op.chainId) && balances.get(op.chainId)! > 0n
    );
    
    if (activeChains.length === 0) {
      throw new Error('No balance on any target chain');
    }
    
    // Step 3: Create UserOps for each chain
    const userOps = await Promise.all(
      activeChains.map(op => this.createUserOp(userAddress, op))
    );
    
    // Step 4: Get single signature for all UserOps
    const digest = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(uint256,address,uint256,bytes,bytes,uint256,uint256,uint256,uint256,uint256,bytes,bytes)[]'],
        [userOps]
      )
    );
    
    const signature = await signer.signMessage(ethers.getBytes(digest));
    
    // Step 5: Submit to bundlers in parallel
    const txHashes = new Map<number, string>();
    
    const submissions = userOps.map((userOp, idx) => {
      const chainId = activeChains[idx].chainId;
      return this.submitUserOp(chainId, userOp, signature)
        .then(txHash => txHashes.set(chainId, txHash))
        .catch(err => console.error(`Chain ${chainId} failed:`, err));
    });
    
    await Promise.all(submissions);
    
    return txHashes;
  }
  
  private async createUserOp(userAddress: string, op: any): Promise<any> {
    const chainId = op.chainId;
    const provider = this.getProvider(chainId);
    const account = await this.getAccountAddress(userAddress, chainId);
    
    return {
      sender: account,
      nonce: await this.getNonce(account, chainId),
      initCode: '0x', // Assume account already created
      callData: this.encodeExecute(op.target, op.value || 0n, op.callData),
      callGasLimit: 200000n,
      verificationGasLimit: 200000n,
      preVerificationGas: 21000n,
      maxFeePerGas: await provider.getGasPrice(),
      maxPriorityFeePerGas: ethers.parseUnits('1', 'gwei'),
      paymasterAndData: '0x', // No sponsorship for now
      signature: '0x', // Will be filled later
    };
  }
  
  private async submitUserOp(chainId: number, userOp: any, signature: string): Promise<string> {
    const bundlerUrl = this.getBundlerUrl(chainId);
    
    const response = await fetch(bundlerUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'eth_sendUserOperation',
        params: [
          { ...userOp, signature },
          this.getEntryPoint(chainId),
        ],
      }),
    });
    
    const result = await response.json();
    
    if (result.error) {
      throw new Error(result.error.message);
    }
    
    return result.result; // UserOp hash
  }
  
  private async queryBalances(userAddress: string): Promise<Map<number, bigint>> {
    // Use BalanceAggregator
    return new Map();
  }
  
  private getProvider(chainId: number): any {
    // Return ethers provider for chain
    return null;
  }
  
  private getBundlerUrl(chainId: number): string {
    const bundlers: Record<number, string> = {
      1: process.env.BUNDLER_ETHEREUM || '',
      8453: process.env.BUNDLER_BASE || '',
      42161: process.env.BUNDLER_ARBITRUM || '',
      10: process.env.BUNDLER_OPTIMISM || '',
    };
    return bundlers[chainId] || '';
  }
  
  private getEntryPoint(chainId: number): string {
    return '0x5FF137D4b0FDCD49DcA30c7B57b04b0541c8F434'; // v0.6
  }
  
  private async getNonce(account: string, chainId: number): Promise<bigint> {
    // Query current nonce from account
    return 0n;
  }
  
  private encodeExecute(target: string, value: bigint, callData: string): string {
    // Encode function call
    return '';
  }
  
  private async getAccountAddress(userAddress: string, chainId: number): Promise<string> {
    // Get deterministic account address
    return '';
  }
}

export default CrossL2IntentExecutor;
```

### 3.2 Account Creation Flow

```typescript
/**
 * Smart account creation: create once, available on all L2s
 * 
 * Flow:
 *   1. User creates account (once, on any chain)
 *   2. Account address is deterministic (CREATE2)
 *   3. Same address works on all L2s
 *   4. Fund with small amount to pay for UserOp gas
 */
class AccountManager {
  async createCrossL2Account(userAddress: string): Promise<string> {
    // Create account deterministically
    const salt = keccak256(abi.encodePacked(userAddress, 0));
    
    // Deploy on Ethereum (gateway)
    const factory = await this.getFactory(1); // chain 1
    const tx = await factory.createAccount(userAddress, salt);
    await tx.wait();
    
    // Get address (same on all chains)
    const accountAddress = await factory.getAccountAddress(userAddress, salt);
    
    // Account now exists on all L2s (conceptually)
    // Can use immediately once funded
    
    return accountAddress;
  }
  
  async fundAccount(
    userAddress: string,
    amountEth: string,
    chainId?: number
  ): Promise<string> {
    const accountAddress = await this.getAccountAddress(userAddress);
    const targetChain = chainId || 1; // Default to Ethereum
    
    // Send ETH to account to pay for UserOp gas
    const signer = this.getSigner(targetChain);
    const tx = await signer.sendTransaction({
      to: accountAddress,
      value: ethers.parseEther(amountEth),
    });
    
    return tx.hash;
  }
  
  private async getAccountAddress(userAddress: string): Promise<string> {
    // Get deterministic address
    return '';
  }
  
  private getFactory(chainId: number): any {
    // Get factory contract
    return null;
  }
  
  private getSigner(chainId: number): any {
    // Get signer for chain
    return null;
  }
}

export default AccountManager;
```

---

## Part 4: Bundler Selection and Routing

### 4.1 Bundler Registry

```typescript
interface BundlerInfo {
  chainId: number;
  rpcUrl: string;
  mempool: 'public' | 'private';
  gasPriceMarkup: number; // e.g., 1.05 = 5% markup
  mevProtection: boolean;
  reputation: number; // 0-100
}

class BundlerRegistry {
  private bundlers: Map<number, BundlerInfo[]> = new Map();
  
  /**
   * Select best bundler for UserOp on chain
   * Factors:
   *   - Gas price markup (lower = better)
   *   - MEV protection
   *   - Reputation
   *   - Current queue size
   */
  async selectBestBundler(chainId: number): Promise<BundlerInfo> {
    const candidates = this.bundlers.get(chainId) || [];
    
    // Score bundlers
    const scored = await Promise.all(
      candidates.map(async bundler => ({
        ...bundler,
        score: await this.scoreBundler(bundler),
      }))
    );
    
    // Sort by score (higher = better)
    scored.sort((a, b) => b.score - a.score);
    
    return scored[0];
  }
  
  private async scoreBundler(bundler: BundlerInfo): Promise<number> {
    let score = 100;
    
    // Deduct for high gas markup
    score -= (bundler.gasPriceMarkup - 1) * 50;
    
    // Bonus for MEV protection
    if (bundler.mevProtection) {
      score += 20;
    }
    
    // Factor in reputation
    score = (score * bundler.reputation) / 100;
    
    return Math.max(0, score);
  }
}
```

---

## Part 5: Sponsored Transactions

### 5.1 Paymaster Sponsorship Model

```typescript
/**
 * DAO/Dapp sponsors gas for escrow operations
 * 
 * Pattern:
 *   1. DAO funds paymaster on each L2
 *   2. User creates UserOp with paymaster
 *   3. Bundler checks paymaster validity
 *   4. Paymaster validates operation is escrow-related
 *   5. Bundler includes operation (gas sponsored)
 *   6. Paymaster deducted for gas cost
 */
class SponsoredOperationExecutor {
  async executeSponsored(
    userAddress: string,
    operation: {
      chainId: number;
      target: string;
      callData: string;
      sponsorBudget: bigint; // Max gas sponsor will pay
    }
  ): Promise<string> {
    const provider = this.getProvider(operation.chainId);
    const account = await this.getAccountAddress(userAddress, operation.chainId);
    
    const userOp = {
      sender: account,
      nonce: await this.getNonce(account, operation.chainId),
      initCode: '0x',
      callData: this.encodeExecute(operation.target, operation.callData),
      callGasLimit: 200000n,
      verificationGasLimit: 200000n,
      preVerificationGas: 21000n,
      maxFeePerGas: ethers.parseUnits('1', 'gwei'),
      maxPriorityFeePerGas: ethers.parseUnits('0.1', 'gwei'),
      paymasterAndData: this.encodePaymasterData(
        operation.chainId,
        operation.sponsorBudget
      ),
      signature: '0x',
    };
    
    // Sign UserOp
    const digest = this.getUserOpHash(userOp, operation.chainId);
    userOp.signature = await this.getSigner().signMessage(ethers.getBytes(digest));
    
    // Submit to bundler
    return this.submitUserOp(operation.chainId, userOp);
  }
  
  private encodePaymasterData(chainId: number, budget: bigint): string {
    const paymasterAddress = this.getPaymasterAddress(chainId);
    return ethers.AbiCoder.defaultAbiCoder().encode(
      ['address', 'uint256'],
      [paymasterAddress, budget]
    );
  }
  
  private getPaymasterAddress(chainId: number): string {
    const addresses: Record<number, string> = {
      1: process.env.PAYMASTER_ETHEREUM || '',
      8453: process.env.PAYMASTER_BASE || '',
      42161: process.env.PAYMASTER_ARBITRUM || '',
      10: process.env.PAYMASTER_OPTIMISM || '',
    };
    return addresses[chainId] || '';
  }
  
  private getProvider(chainId: number): any {
    return null;
  }
  
  private async getAccountAddress(userAddress: string, chainId: number): string {
    return '';
  }
  
  private async getNonce(account: string, chainId: number): bigint {
    return 0n;
  }
  
  private encodeExecute(target: string, callData: string): string {
    return '';
  }
  
  private getUserOpHash(userOp: any, chainId: number): string {
    return '';
  }
  
  private getSigner(): any {
    return null;
  }
  
  private async submitUserOp(chainId: number, userOp: any): Promise<string> {
    return '';
  }
}
```

---

## Part 6: Security Considerations

### 6.1 Signature Validation

```solidity
/**
 * CRITICAL: Validate that signature covers intended operations on each chain
 * 
 * Attack vector:
 *   - User signs intent for "settle on Base"
 *   - Attacker replays signature on Arbitrum
 *   - User's balance withdrawn twice
 * 
 * Prevention: Chain ID included in signature digest
 */

// UserOp hash includes chainId
bytes32 userOpHash = keccak256(abi.encodePacked(
  chainId,  // IMPORTANT: Chain-specific
  userOp.sender,
  userOp.nonce,
  userOp.callData
));

// User signs this chain-specific hash
signature = sign(userOpHash);
```

### 6.2 Replay Protection

```typescript
// Check each chain has incremented nonce
async function checkNoReplay(
  userAddress: string,
  userOps: UserOperation[]
): Promise<void> {
  const nonces = await Promise.all(
    userOps.map(op => this.getNonce(op.sender, op.chainId))
  );
  
  // Verify nonce matches UserOp (prevents replay)
  userOps.forEach((op, i) => {
    if (op.nonce !== nonces[i]) {
      throw new Error(`Replay detected on chain ${op.chainId}`);
    }
  });
}
```

### 6.3 Account Ownership Validation

```solidity
/**
 * Ensure account owner is consistent across all L2s
 * 
 * Rule: All replicas must have same owner
 */
function validateAccountConsistency(address account, address owner) internal {
  for (uint256 i = 0; i < chainIds.length; i++) {
    address accountOwner = getOwnerOnChain(account, chainIds[i]);
    require(accountOwner == owner, "Account ownership mismatch on L2");
  }
}
```

---

## Part 7: Gas Optimization

### 7.1 UserOp Gas Estimation

```typescript
/**
 * Pre-flight gas estimation before submitting UserOp
 * Prevents failed transactions
 */
async function estimateUserOpGas(
  userOp: UserOperation,
  chainId: number
): Promise<{
  callGasLimit: bigint;
  verificationGasLimit: bigint;
  preVerificationGas: bigint;
}> {
  const provider = this.getProvider(chainId);
  const entryPoint = new ethers.Contract(
    this.getEntryPoint(chainId),
    IEntryPointAbi,
    provider
  );
  
  // Estimate gas for execution
  const callGasLimit = await provider.estimateGas({
    from: userOp.sender,
    to: userOp.callData.slice(0, 4), // target
    data: userOp.callData,
  });
  
  return {
    callGasLimit: callGasLimit * 110n / 100n, // +10% buffer
    verificationGasLimit: 200000n,
    preVerificationGas: 21000n,
  };
}
```

### 7.2 Batch Optimization

```typescript
/**
 * Optimize multiple UserOps into single batch
 * Amortize fixed costs
 */
function optimizeBatch(userOps: UserOperation[]): UserOperation[] {
  // Group by sender
  const bySender = groupBy(userOps, 'sender');
  
  // For each sender, batch into one callData if possible
  const optimized: UserOperation[] = [];
  
  for (const [sender, ops] of Object.entries(bySender)) {
    if (ops.length === 1) {
      optimized.push(ops[0]);
      continue;
    }
    
    // Batch multiple operations for same sender
    const batchCallData = encodeBatchCall(ops.map(op => op.callData));
    
    optimized.push({
      ...ops[0],
      callData: batchCallData,
      callGasLimit: ops.reduce((sum, op) => sum + op.callGasLimit, 0n),
    });
  }
  
  return optimized;
}
```

---

## Part 8: Deployment Checklist

- [ ] Deploy EntryPoint v0.6 on all L2s
- [ ] Deploy AccountFactory on Ethereum
- [ ] Deploy Paymaster on all L2s
- [ ] Set up bundlers (or use existing like Alchemy/Pimlico)
- [ ] Configure gas sponsorship budget
- [ ] Create account creation UI
- [ ] Add AA to wallet dashboard
- [ ] Test cross-L2 UserOp execution
- [ ] Audit paymaster logic
- [ ] Document for users

---

## References

- [EIP-4337 Spec](https://eips.ethereum.org/EIPS/eip-4337)
- [Account Abstraction Book](https://4337.mirror.xyz/)
- [Pimlico AA Infrastructure](https://www.pimlico.io/)
- [Alchemy AA SDK](https://www.alchemy.com/account-abstraction)

---

**Last Updated**: Feb 4, 2026  
**Status**: Design Proposal - Ready for Phase 3 Planning
