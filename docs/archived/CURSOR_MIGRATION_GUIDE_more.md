# Cursor Migration Guide (apt-installed package)

**Date:** 2025-01-27  
**Purpose:** Ensure no LLM memory/context is lost when migrating to apt-installed Cursor package

---

## Overview

When installing Cursor via apt package, the application will use the same user data directory (`~/.cursor/`), so most data should persist automatically. However, this guide ensures no context or conversation history is lost during the transition.

---

## Data Locations

### Global Cursor Data (`~/.cursor/`)

These locations contain cross-project data:

1. **Agent Transcripts** (conversation history)
   - Location: `~/.cursor/projects/{project-path}/agent-transcripts/`
   - Files: `*.txt`, `*.json`
   - **Critical:** Contains full conversation history with LLM

2. **Agent Tools**
   - Location: `~/.cursor/projects/{project-path}/agent-tools/`
   - Files: `*.txt` (tool definitions)
   - **Important:** Contains agent tool configurations

3. **MCP Configurations**
   - Location: `~/.cursor/projects/{project-path}/mcps/`
   - Files: `*.json` (MCP server configs)
   - **Important:** Contains MCP server configurations (e.g., Codacy)

4. **Plans**
   - Location: `~/.cursor/plans/`
   - Files: `*.plan.md`
   - **Important:** Contains active plans and tasks

5. **AI Tracking Database**
   - Location: `~/.cursor/ai-tracking/ai-code-tracking.db`
   - **Important:** Contains AI code tracking history

6. **IDE State**
   - Location: `~/.cursor/ide_state.json`
   - **Moderate:** Contains IDE state and preferences

7. **MCP Global Config**
   - Location: `~/.cursor/mcp.json`
   - **Important:** Contains global MCP server configurations

### Project-Specific Data

Each project may have its own `.cursor/` directory:

- Location: `{project-root}/.cursor/`
- Contents vary by project

---

## Migration Steps

### Step 1: Backup Current Data (Before apt install)

```bash
# Create backup directory
mkdir -p ~/cursor-backup-$(date +%Y%m%d)

# Backup global Cursor data
cp -r ~/.cursor ~/cursor-backup-$(date +%Y%m%d)/.cursor

# Backup project-specific .cursor directories (optional)
find ~/Code -maxdepth 2 -type d -name ".cursor" -exec cp -r {} ~/cursor-backup-$(date +%Y%m%d)/.cursor-project-{} \;
```

### Step 2: Verify Backup

```bash
# Check agent transcripts exist
ls -la ~/cursor-backup-$(date +%Y%m%d)/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/agent-transcripts/

# Check MCP configs exist
ls -la ~/cursor-backup-$(date +%Y%m%d)/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/mcps/

# Check plans exist
ls -la ~/cursor-backup-$(date +%Y%m%d)/.cursor/plans/
```

### Step 3: Install apt Package

```bash
# Install Cursor via apt (example - actual command may vary)
sudo apt update
sudo apt install cursor
```

### Step 4: Verify Data Persisted

After installation, check that data is still accessible:

```bash
# Check agent transcripts
ls -la ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/agent-transcripts/

# Check MCP configs
ls -la ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/mcps/

# Check plans
ls -la ~/.cursor/plans/

# Check AI tracking
ls -la ~/.cursor/ai-tracking/
```

### Step 5: Restore if Needed

If data is missing after installation:

```bash
# Restore from backup
cp -r ~/cursor-backup-$(date +%Y%m%d)/.cursor/* ~/.cursor/
```

---

## Project-Specific Context

### hardhat-deploy-hybrid Project

**Current Context Location:**

```
~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/
├── agent-transcripts/
│   └── *.txt (conversation history)
├── mcps/
│   └── user-codacy/
│       └── tools/
│           └── *.json (MCP tool configs)
└── (other files)
```

**Important Files:**

- Agent transcripts contain full conversation history
- MCP configurations for Codacy integration
- Plans may contain active task lists

**Verification:**

```bash
# Check transcript count
find ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/agent-transcripts -type f | wc -l

# Check latest transcript
ls -lt ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/agent-transcripts/ | head -5
```

---

## Expected Behavior

### What Should Persist Automatically

✅ **Agent Transcripts** - Conversation history should persist  
✅ **MCP Configurations** - Should persist if same data directory  
✅ **Plans** - Should persist  
✅ **AI Tracking Database** - Should persist  
✅ **IDE Preferences** - Should persist

### What Might Reset

⚠️ **Extension State** - May reset (not critical)  
⚠️ **Window Layout** - May reset (not critical)  
⚠️ **Recent Files** - May reset (not critical)

### What Needs Manual Reconfiguration

🔧 **MCP Server Connections** - If configuration format changed  
🔧 **Extension Installations** - Will need reinstall if missing  
🔧 **Workspace Settings** - May need reconfiguration

---

## Verification Checklist

After apt installation, verify:

- [ ] Agent transcripts are accessible
- [ ] MCP configurations are present
- [ ] Plans are present
- [ ] AI tracking database exists
- [ ] Recent conversation history is visible in Cursor
- [ ] MCP servers (e.g., Codacy) are configured
- [ ] Project context is recognized
- [ ] Code suggestions work correctly

---

## Troubleshooting

### Issue: Transcripts Not Visible

**Symptoms:** No conversation history in Cursor

**Solution:**

```bash
# Check if files exist
ls -la ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/agent-transcripts/

# If missing, restore from backup
cp -r ~/cursor-backup-*/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/agent-transcripts/ \
      ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/
```

### Issue: MCP Servers Not Working

**Symptoms:** MCP integrations (e.g., Codacy) not functioning

**Solution:**

```bash
# Check MCP config exists
cat ~/.cursor/mcp.json

# Check project-specific MCP configs
ls -la ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/mcps/

# Restore if needed
cp -r ~/cursor-backup-*/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/mcps/ \
      ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/
```

### Issue: Plans Missing

**Symptoms:** Active plans/tasks not visible

**Solution:**

```bash
# Check plans directory
ls -la ~/.cursor/plans/

# Restore if needed
cp -r ~/cursor-backup-*/.cursor/plans/* ~/.cursor/plans/
```

### Issue: Project Context Lost

**Symptoms:** Cursor doesn't recognize project structure

**Solution:**

1. Open project in Cursor: `cursor ~/Code/hardhat-deploy-hybrid`
2. Wait for indexing to complete
3. Check if `.cursor/` directory is created in project root
4. If needed, restart Cursor

---

## Prevention: Regular Backups

To avoid data loss in future:

```bash
# Add to crontab for weekly backups
0 2 * * 0 cp -r ~/.cursor ~/cursor-backups/cursor-$(date +\%Y\%m\%d) && find ~/cursor-backups -type d -mtime +30 -exec rm -rf {} \;
```

---

## Data Size Estimate

For `hardhat-deploy-hybrid` project:

```bash
# Check current size
du -sh ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/
```

Typical sizes:

- Agent transcripts: ~1-10 MB (grows over time)
- MCP configs: ~10-100 KB
- Plans: ~1-100 KB
- AI tracking: ~1-10 MB

---

## Notes

1. **User Data Directory:** The apt package should use the same `~/.cursor/` directory, so data should persist automatically.

2. **Project Paths:** Project paths in `~/.cursor/projects/` use normalized paths (e.g., `home-user-Code-hardhat-deploy-hybrid`). These should remain the same after apt install.

3. **MCP Servers:** If MCP configuration format changed in new version, may need manual reconfiguration.

4. **Extension State:** Extension data may reset, but this is typically not critical as extensions can be reinstalled.

5. **Workspace Settings:** Workspace-specific settings may need reconfiguration, but project code and context should persist.

---

## Quick Reference

### Backup Command

```bash
cp -r ~/.cursor ~/cursor-backup-$(date +%Y%m%d)
```

### Verify Data

```bash
ls -la ~/.cursor/projects/home-user-Code-hardhat-deploy-hybrid/agent-transcripts/
```

### Restore Data

```bash
cp -r ~/cursor-backup-*/.cursor/* ~/.cursor/
```

---

**Document Version:** 1.0  
**Last Updated:** 2025-01-27  
**For:** Cursor apt package migration
