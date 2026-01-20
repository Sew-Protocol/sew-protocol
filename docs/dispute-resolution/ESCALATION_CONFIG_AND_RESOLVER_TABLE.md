# EscalationConfig and Resolver Table Usage

## EscalationConfig - Round Enable/Disable Control

### Purpose

`escalationConfig` mapping (`mapping(uint8 => EscalationConfig)`) controls which escalation rounds are enabled. This is critical for:

- **Disabling Kleros (round 2) at launch** - Round 2 is disabled by default (`enabled: false` in initialization)
- **Gradual rollout** - Enable rounds as system matures
- **Emergency controls** - Disable rounds if issues arise

### Structure

```solidity
struct EscalationConfig {
  address resolver; // Resolver for this level (or address(0) for dynamic)
  uint256 fee; // Fee required to escalate to this level (DEPRECATED - now using bonds)
  bool enabled; // Whether this level is enabled
}
```

### Current Usage

- **Round 0 (Resolver)**: `enabled: true` - Always enabled
- **Round 1 (Senior Resolver)**: `enabled: true` - Enabled
- **Round 2 (Kleros)**: `enabled: false` - Disabled by default, enabled when `setExternalResolver()` is called

### Key Functions

- `canEscalate()`: Checks `escalationConfig[nextRound].enabled` before allowing escalation
- `executeEscalation()`: Checks `escalationConfig[toRound].enabled` before executing
- `queueEscalationConfig()` / `activateEscalationConfig()`: Governance functions to update config (slow lane)

### Note on Fees

The `fee` field in `EscalationConfig` is now **deprecated** - escalation bonds are handled via `escalationCostConfig` instead. The `enabled` field is still actively used to control round availability.

---

## Resolver Lookup Table (Resolution Table)

### Purpose

The `resolutionTable` mapping (`mapping(bytes32 => ResolutionTableEntry)`) enables **category-based resolver routing**. Each escrow is assigned a category key, and the table maps categories to resolution configuration.

### Structure

```solidity
struct ResolutionTableEntry {
  uint8 maxRound; // Maximum round (0-2: 0=resolver only, 1=+senior, 2=+Kleros)
  uint256 escalationFee; // Fee required for escalation (LEGACY - use cost curves in v2)
  bool enabled; // Whether this entry is active
  string categoryName; // Human-readable category name
}
```

### Category Assignment

- **Per-escrow category**: `escrowCategory[workflowId]` stores the category key for each escrow
- **Category setting**: `setEscrowCategory(workflowId, categoryKey)` called by escrow contract during dispute initialization
- **Auto-categorization**: `ResolutionTableLibrary.autoCategorize()` can generate category keys from escrow data (token + amount tier)

### Resolver Selection Flow

#### Round 0 (Initial Resolver Selection)

1. `getDisputeResolver()` checks if escrow has category: `escrowCategory[workflowId]`
2. If category exists and `resolutionTable[cat].enabled`:
   - Uses category-specific selection: `selectResolverRoundRobin(cat, false)`
3. Fallback: Uses default category `bytes32(0)`: `selectResolverRoundRobin(bytes32(0), false)`

#### Round 1 (Senior Resolver Selection)

- Uses same category: `selectResolverRoundRobin(escrowCategory[workflowId], true)`
- The `true` parameter selects from senior resolver pool instead of regular resolver pool

#### Round 2 (Kleros)

- Always uses `externalResolver` address (not category-based)

### Category-Specific Counters

- `categoryResolverIndex[category]`: Round-robin counter for regular resolvers per category
- `categorySeniorResolverIndex[category]`: Round-robin counter for senior resolvers per category
- Each category maintains its own round-robin state, ensuring balanced distribution within categories

### Key Functions

- `setResolutionTableEntry(categoryKey, entry)`: Governance function to configure category
- `getResolutionTableEntry(categoryKey)`: View function to read category config
- `selectResolverRoundRobin(category, useSenior)`: Internal function that uses category for selection
- `advanceRoundRobinCounter(category, useSenior)`: Updates category-specific counter

### Current Status

- Table infrastructure is in place
- Category assignment happens during dispute initialization
- Category-based selection is implemented for rounds 0 and 1
- Round 2 (Kleros) is not category-based (always uses `externalResolver`)

---

## Summary: Per-Round Resolver Selection

### Round 0 (Resolver)

- **Selection**: Category-based round-robin from `approvedResolvers` pool
- **Category**: Uses `escrowCategory[workflowId]` if set, else `bytes32(0)`
- **Method**: `selectResolverRoundRobin(escrowCategory[workflowId], false)`

### Round 1 (Senior Resolver)

- **Selection**: Category-based round-robin from `approvedSeniorResolvers` pool
- **Category**: Uses same `escrowCategory[workflowId]` as round 0
- **Method**: `selectResolverRoundRobin(escrowCategory[workflowId], true)`

### Round 2 (Kleros/External)

- **Selection**: Fixed address (`externalResolver`)
- **Category**: Not category-based (same resolver for all escrows)
- **Control**: Enabled/disabled via `escalationConfig[2].enabled`

---

## Relationship to Escalation Bonds

- **EscalationConfig**: Controls round availability (enabled/disabled)
- **EscalationCostConfig**: Controls bond amounts (quadratic curve, base cost, step size)
- These are **separate concerns**: A round can be enabled but have zero bond (or vice versa in theory)
