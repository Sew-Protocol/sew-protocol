# Cursor Settings & Index Migration Guide

## Overview

This guide explains how to migrate Cursor IDE settings, indexes, and agent configurations from the old directory (`starter-scaffold-eth`) to the new directory with pnpm, Hardhat classic, and Foundry.

---

## What to Migrate

### 1. Cursor Rules (`.cursorrules` or `.cursor/rules/`)
- **Purpose**: Project-specific rules for AI assistant behavior
- **Location**: Project root or `.cursor/` directory
- **Files**: 
  - `.cursorrules` (root level)
  - `.cursor/rules/*.mdc` (rule files)

### 2. Cursor Index Cache
- **Purpose**: Pre-computed codebase indexes for faster AI responses
- **Location**: `.cursor/` directory
- **Files**:
  - `.cursor/index/` (index cache)
  - `.cursor/cache/` (general cache)

### 3. Agent Settings
- **Purpose**: Cursor agent configuration
- **Location**: `.cursor/` directory or workspace settings
- **Files**:
  - `.cursor/agent.json` (if exists)
  - `.vscode/settings.json` (workspace settings)

### 4. Workspace Settings
- **Purpose**: IDE configuration
- **Location**: `.vscode/` directory
- **Files**:
  - `.vscode/settings.json`
  - `.vscode/extensions.json`

---

## Migration Steps

### Step 1: Identify Source Files

**In old directory** (`/home/user/Code/scaffold-eth-2/starter-scaffold-eth/`):

```bash
# Check for cursor rules
ls -la .cursorrules
ls -la .cursor/rules/

# Check for cursor cache/index
ls -la .cursor/index/
ls -la .cursor/cache/

# Check for workspace settings
ls -la .vscode/
```

### Step 2: Copy Cursor Rules

**Option A: Single `.cursorrules` file**
```bash
# From old directory
cp .cursorrules /path/to/new/directory/.cursorrules
```

**Option B: Multiple rule files**
```bash
# Create rules directory in new project
mkdir -p /path/to/new/directory/.cursor/rules

# Copy all rule files
cp -r .cursor/rules/* /path/to/new/directory/.cursor/rules/
```

**Option C: Merge rules**
If you have both formats, merge them:
```bash
# Copy single file
cp .cursorrules /path/to/new/directory/.cursorrules

# Or copy directory structure
cp -r .cursor/rules /path/to/new/directory/.cursor/
```

### Step 3: Copy Workspace Settings

```bash
# Create .vscode directory if it doesn't exist
mkdir -p /path/to/new/directory/.vscode

# Copy settings
cp .vscode/settings.json /path/to/new/directory/.vscode/settings.json 2>/dev/null || echo "No settings.json found"
cp .vscode/extensions.json /path/to/new/directory/.vscode/extensions.json 2>/dev/null || echo "No extensions.json found"
```

### Step 4: Update Rule Files for New Structure

**Important**: Update paths and references in rule files:

1. **Update package manager references**:
   - Change `yarn` → `pnpm` where appropriate
   - Update workspace commands

2. **Update directory structure**:
   - Verify paths match new structure
   - Update any hardcoded paths

3. **Update framework references**:
   - Add Foundry references if needed
   - Update Hardhat version references

**Example update** (`.cursorrules` or rule file):
```markdown
# Old
- `yarn chain`: Starts a local blockchain network
- `yarn deploy`: Deploys SE-2 default contract

# New
- `pnpm chain`: Starts a local blockchain network
- `pnpm deploy`: Deploys SE-2 default contract
- `forge test`: Run Foundry tests
- `forge test --fuzz`: Run fuzzing tests
```

### Step 5: Rebuild Index (Recommended)

**Cursor will rebuild indexes automatically**, but you can force it:

1. **Close and reopen Cursor** in the new directory
2. **Or manually trigger reindex**:
   - Open Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`)
   - Run: "Cursor: Rebuild Index"

### Step 6: Verify Migration

1. **Check rules are loaded**:
   - Open a file in the new directory
   - Ask Cursor a project-specific question
   - Verify it uses project rules

2. **Check workspace settings**:
   - Verify extensions are suggested
   - Check settings are applied

---

## Automated Migration Script

Create a script to automate the migration:

```bash
#!/bin/bash
# migrate-cursor-settings.sh

OLD_DIR="/home/user/Code/scaffold-eth-2/starter-scaffold-eth"
NEW_DIR="/path/to/new/directory"

echo "Migrating Cursor settings from $OLD_DIR to $NEW_DIR"

# Create necessary directories
mkdir -p "$NEW_DIR/.cursor/rules"
mkdir -p "$NEW_DIR/.vscode"

# Copy cursor rules
if [ -f "$OLD_DIR/.cursorrules" ]; then
    echo "Copying .cursorrules..."
    cp "$OLD_DIR/.cursorrules" "$NEW_DIR/.cursorrules"
fi

if [ -d "$OLD_DIR/.cursor/rules" ]; then
    echo "Copying .cursor/rules/..."
    cp -r "$OLD_DIR/.cursor/rules"/* "$NEW_DIR/.cursor/rules/" 2>/dev/null || true
fi

# Copy workspace settings
if [ -f "$OLD_DIR/.vscode/settings.json" ]; then
    echo "Copying .vscode/settings.json..."
    cp "$OLD_DIR/.vscode/settings.json" "$NEW_DIR/.vscode/settings.json"
fi

if [ -f "$OLD_DIR/.vscode/extensions.json" ]; then
    echo "Copying .vscode/extensions.json..."
    cp "$OLD_DIR/.vscode/extensions.json" "$NEW_DIR/.vscode/extensions.json"
fi

echo "Migration complete!"
echo "Next steps:"
echo "1. Update rule files for new directory structure"
echo "2. Update package manager references (yarn → pnpm)"
echo "3. Add Foundry references if needed"
echo "4. Reopen Cursor in new directory"
```

**Usage**:
```bash
chmod +x migrate-cursor-settings.sh
./migrate-cursor-settings.sh
```

---

## What NOT to Migrate

### ❌ Don't Copy Index Cache
**Why**: Index cache is project-specific and will be rebuilt automatically
```bash
# DON'T copy these
.cursor/index/
.cursor/cache/
```

**Reason**: 
- Index cache is tied to specific file paths
- Will be incorrect in new directory
- Cursor will rebuild automatically

### ❌ Don't Copy Node Modules References
**Why**: Different package manager (pnpm vs yarn) means different structure

### ❌ Don't Copy Build Artifacts
**Why**: Will be regenerated
```bash
# DON'T copy
node_modules/
artifacts/
cache/
out/
```

---

## Updating Rules for New Setup

### Example: Updated `.cursorrules` for New Directory

```markdown
---
description: Scaffold-ETH 2 with Foundry and Hardhat
globs: 
alwaysApply: true
---

This codebase contains Scaffold-ETH 2 (SE-2), everything you need to build dApps on Ethereum. 
Its tech stack is NextJS, RainbowKit, Wagmi and Typescript. Supports Hardhat and Foundry.

It's a pnpm monorepo that contains following packages:

- HARDHAT (`packages/hardhat`): The solidity framework to write, test and deploy EVM Smart Contracts.
- NextJS (`packages/nextjs`): The UI framework extended with utilities to make interacting with Smart Contracts easy.

## Testing Framework

This project uses a hybrid testing approach:
- **Foundry**: For invariant testing, fuzzing, and gas optimization
  - Tests located in `packages/hardhat/test/foundry/`
  - Run with: `forge test` or `pnpm test:foundry`
- **Hardhat**: For integration tests and deployment scripts
  - Tests located in `packages/hardhat/test/`
  - Run with: `pnpm test` or `hardhat test`

## Development Flow

- Start SE-2 locally:
  - `pnpm chain`: Starts a local blockchain network
  - `pnpm deploy`: Deploys SE-2 default contract
  - `pnpm start`: Starts the frontend
- Write a Smart Contract
- Deploy it locally (`pnpm deploy`)
- Test with Foundry (`forge test`) or Hardhat (`pnpm test`)
- Create your custom UI using all the SE-2 components, hooks, and utilities.
```

---

## Troubleshooting

### Issue: Rules Not Loading

**Symptoms**: Cursor doesn't use project rules

**Solutions**:
1. Check file location (should be in project root or `.cursor/rules/`)
2. Check file format (should be `.mdc` or `.cursorrules`)
3. Restart Cursor
4. Check Cursor settings → Rules → Project rules enabled

### Issue: Index Not Rebuilding

**Symptoms**: Slow AI responses, outdated context

**Solutions**:
1. Manually trigger rebuild: Command Palette → "Cursor: Rebuild Index"
2. Check `.cursor/` directory permissions
3. Clear cache: Delete `.cursor/cache/` (will rebuild)
4. Restart Cursor

### Issue: Workspace Settings Not Applied

**Symptoms**: Extensions not suggested, settings not working

**Solutions**:
1. Check `.vscode/settings.json` syntax (valid JSON)
2. Verify file is in project root
3. Reload window: Command Palette → "Developer: Reload Window"

---

## Best Practices

### 1. Version Control
**Do commit**:
- `.cursorrules` or `.cursor/rules/`
- `.vscode/settings.json`
- `.vscode/extensions.json`

**Don't commit**:
- `.cursor/index/` (index cache)
- `.cursor/cache/` (general cache)
- User-specific settings

### 2. Gitignore
Add to `.gitignore`:
```
.cursor/index/
.cursor/cache/
.vscode/settings.json  # If user-specific
```

### 3. Team Sharing
- Share `.cursorrules` or rule files via git
- Document any team-specific rules
- Keep rules updated with project changes

---

## Summary

### Quick Migration Checklist

- [ ] Copy `.cursorrules` or `.cursor/rules/` to new directory
- [ ] Copy `.vscode/settings.json` (if exists)
- [ ] Copy `.vscode/extensions.json` (if exists)
- [ ] Update rule files for new structure (pnpm, Foundry, etc.)
- [ ] Update package manager references
- [ ] Add Foundry references if needed
- [ ] Reopen Cursor in new directory
- [ ] Verify rules are loaded
- [ ] Let Cursor rebuild indexes automatically

### Files to Migrate
✅ `.cursorrules` or `.cursor/rules/*.mdc`
✅ `.vscode/settings.json`
✅ `.vscode/extensions.json`

### Files NOT to Migrate
❌ `.cursor/index/` (will rebuild)
❌ `.cursor/cache/` (will rebuild)
❌ `node_modules/` (different structure)
❌ Build artifacts

---

**Last Updated**: Current Date

