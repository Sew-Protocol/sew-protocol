# Top 3 Priorities Proposal

**Date**: Current  
**Exclusions**: Contract size issues (addressed separately tomorrow)

---

## Priority 1: Fix Test Failures (86 Failing Tests) 🔴 **CRITICAL**

### Impact

- **Status**: ⚠️ **86 FAILING TESTS** - Blocking all merges
- **Severity**: **CRITICAL** - Tests must pass before any production deployment
- **Effort**: Medium (systematic find-and-replace with verification)

### Root Causes

1. **Function Name Changes** (~60 tests)
   - `escrowTransfer()` → `createEscrow()`
   - `timedEscrowTransfer()` → `createEscrow()` with settings
   - Tests still using deprecated function names

2. **Deprecated Function Calls** (~5 tests)
   - `setAuthorizedResolver()` is deprecated
   - Tests need to use resolution module setup instead

3. **Missing Module Deployments** (~10 tests)
   - Tests missing required module setup
   - Resolution modules not deployed in test setup

4. **Ambiguous Function Calls** (~11 tests)
   - Overloaded `createEscrow()` functions need `.getFunction()` disambiguation
   - Ethers.js cannot distinguish between overloads automatically

### Implementation Plan

#### Phase 1: Function Name Updates (2-3 hours)

```bash
# Find all instances
grep -r "escrowTransfer\|timedEscrowTransfer" test/

# Update pattern:
# OLD: await contract.connect(sender).escrowTransfer(recipient.address, amount)
# NEW: await contract.connect(sender).getFunction("createEscrow(address,uint256)").send(recipient.address, amount)

# OLD: await contract.timedEscrowTransfer(recipient.address, amount, releaseTime, cancelTime)
# NEW: await contract.getFunction("createEscrow(address,uint256,uint256,uint256)").send(recipient.address, amount, releaseTime, cancelTime)
```

#### Phase 2: Deprecated Function Removal (1 hour)

```bash
# Remove setAuthorizedResolver() calls
# Replace with: await setupResolutionModule(contract, owner, resolver.address)
```

#### Phase 3: Module Setup Fixes (2-3 hours)

```bash
# Add to beforeEach() in affected test files:
await setupResolutionModule(escrowableERC20, owner, resolver.address);
```

#### Phase 4: Overload Disambiguation (1-2 hours)

```typescript
// Pattern for overloaded functions:
await contract
  .connect(sender)
  .getFunction('createEscrow(address,uint256)')
  .send(recipient.address, amount);
```

### Success Criteria

- ✅ All 86 tests passing
- ✅ Test suite runs in < 5 minutes
- ✅ No deprecated function calls
- ✅ All tests use proper module setup

### Estimated Time

**6-9 hours** (1 day)

---

## Priority 2: Standardize Solidity Version Documentation 📝 **HIGH**

### Impact

- **Status**: ⚠️ **INCONSISTENCY** - Documentation doesn't match code
- **Severity**: **HIGH** - Causes confusion for contributors
- **Effort**: Low (documentation update only)

### Current State

**Code Reality**:

- ✅ All 41 contracts use `pragma solidity ^0.8.33`
- ✅ Consistent across entire codebase

**Documentation Says**:

- ❌ CONTRIBUTING.md specifies `^0.8.28`
- ❌ TECHNICAL_OVERVIEW.md says `0.8.33` (correct, but inconsistent with CONTRIBUTING.md)

### Implementation Plan

#### Option A: Update Documentation to Match Code (Recommended)

```markdown
# Update CONTRIBUTING.md

- **Solidity Version**: `^0.8.33` # Changed from ^0.8.28
```

**Rationale**:

- Code is already consistent at `^0.8.33`
- No code changes needed
- Quick fix (15 minutes)

#### Option B: Downgrade Code to Match Documentation

```bash
# Update all 41 contracts
# Change: pragma solidity ^0.8.33;
# To:     pragma solidity ^0.8.28;
```

**Rationale**:

- Matches existing documentation
- But requires re-testing all contracts
- Risk of missing features in 0.8.33

### Recommendation

**Option A** - Update documentation to reflect current code state (`^0.8.33`)

### Files to Update

1. `docs/CONTRIBUTING.md` - Line 91
2. Verify `docs/TECHNICAL_OVERVIEW.md` is correct (already says 0.8.33)

### Success Criteria

- ✅ CONTRIBUTING.md matches actual code version
- ✅ All documentation consistent
- ✅ No confusion for new contributors

### Estimated Time

**15-30 minutes**

---

## Priority 3: Add CI/CD Automation 🤖 **HIGH**

### Impact

- **Status**: ⚠️ **MISSING** - No automated quality checks
- **Severity**: **HIGH** - Prevents catching issues early
- **Effort**: Medium (setup GitHub Actions workflow)

### Current State

**What's Missing**:

- ❌ No automated test runs on PR
- ❌ No contract size checks in CI
- ❌ No linting enforcement
- ❌ No formatting checks
- ❌ No type checking
- ❌ No coverage reporting

**What Exists**:

- ✅ `pnpm test` script works
- ✅ `pnpm lint` script exists
- ✅ `pnpm format` script exists
- ✅ `pnpm typecheck` script exists
- ✅ `pnpm size:check` script exists

### Implementation Plan

#### Create `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v2
        with:
          version: 8
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'pnpm'

      - name: Install dependencies
        run: pnpm install

      - name: Compile contracts
        run: pnpm compile

      - name: Run tests
        run: pnpm test

      - name: Check contract sizes
        run: pnpm size:check

      - name: Lint
        run: pnpm lint

      - name: Type check
        run: pnpm typecheck

      - name: Check formatting
        run: pnpm format --check
```

#### Optional: Add Coverage Reporting

```yaml
- name: Generate coverage
  run: pnpm coverage

- name: Upload coverage
  uses: codecov/codecov-action@v3
  with:
    files: ./coverage/coverage.json
```

### Benefits

1. **Prevents Broken PRs**: Catches test failures before merge
2. **Enforces Standards**: Ensures linting, formatting, type safety
3. **Size Monitoring**: Alerts on contract size increases
4. **Documentation**: CI status shows project health
5. **Developer Confidence**: Know immediately if changes break things

### Success Criteria

- ✅ CI runs on all PRs
- ✅ All checks pass before merge
- ✅ Contract size warnings visible
- ✅ Coverage reports generated (optional)

### Estimated Time

**2-3 hours** (including testing and refinement)

---

## Summary

| Priority | Task                         | Impact                  | Effort | Time      |
| -------- | ---------------------------- | ----------------------- | ------ | --------- |
| 🔴 **1** | Fix Test Failures            | **CRITICAL** - Blocking | Medium | 6-9 hours |
| 📝 **2** | Standardize Solidity Version | **HIGH** - Consistency  | Low    | 15-30 min |
| 🤖 **3** | Add CI/CD Automation         | **HIGH** - Prevention   | Medium | 2-3 hours |

### Total Estimated Time

**8-12 hours** (1-1.5 days)

### Recommended Order

1. **Priority 2** (15-30 min) - Quick win, removes confusion
2. **Priority 1** (6-9 hours) - Critical blocker, must be done
3. **Priority 3** (2-3 hours) - Prevents future issues

### Rationale

- **Priority 2 first**: Quick documentation fix removes confusion immediately
- **Priority 1 second**: Critical blocker that must be resolved before any production work
- **Priority 3 third**: Once tests pass, CI/CD ensures they stay passing

---

## Next Steps

1. ✅ Review and approve priorities
2. Start with Priority 2 (quick win)
3. Tackle Priority 1 (test fixes)
4. Implement Priority 3 (CI/CD)
5. Verify all priorities complete

---

**Last Updated**: Current  
**Status**: Proposal - Awaiting Approval
