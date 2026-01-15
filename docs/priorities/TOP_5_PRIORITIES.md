# Top 5 Priorities - Overall (Code, Docs, Tests)

**Date:** 2026-01-06  
**Status:** Pre-Mainnet  
**Purpose:** Consolidated list of top 5 priorities across all areas

---

## 1. 🔴 SECURITY.md - Security Contact & Disclosure Policy (DOCS)

**Priority:** 🔴 **CRITICAL** - Blocks mainnet deployment  
**Type:** Documentation  
**Estimated Time:** 30 minutes  
**Source:** `docs/OUTSTANDING_ISSUES.md` #1

**What's Missing:**

- `SECURITY.md` file in repository root
- Security contact information
- Responsible disclosure policy (e.g., 90-day coordinated disclosure)
- How to report vulnerabilities
- PGP key or secure contact method (optional but recommended)

**Why Critical:**

- Required by Mainnet Checklist Section B (Security Baseline)
- Essential for responsible disclosure
- Expected by auditors and security researchers
- Quick win (30 minutes)

**Action Items:**

- [ ] Create `SECURITY.md` with security contact
- [ ] Define disclosure policy
- [ ] Add security contact email/contact method
- [ ] Link from README.md

**Reference:** Mainnet Checklist Section B - "Responsible disclosure: SECURITY.md with a security contact + policy"

---

## 2. 🟠 Emergency + Recovery Drills (TEST/DOCS)

**Priority:** 🟠 **MUST-PASS GATE** - Required before mainnet  
**Type:** Testing + Documentation  
**Estimated Time:** 2-4 hours  
**Source:** `docs/OUTSTANDING_ISSUES.md` #7

**What's Missing:**

- Base Sepolia deployment rehearsal (documented with tx hashes)
- Emergency drill (pause, disable yield, lower caps)
- Recovery drill (unpause via timelock)
- Documented drill results

**Why Critical:**

- Must-pass gate for mainnet deployment
- Validates operational procedures work
- Provides evidence of readiness
- Identifies issues before mainnet

**Action Items:**

- [ ] Perform Base Sepolia deployment rehearsal
- [ ] Document deployment rehearsal with tx hashes
- [ ] Perform emergency drill (pause protocol)
- [ ] Perform recovery drill (unpause via timelock)
- [ ] Document drill results in `governance/runbooks/`
- [ ] Create drill evidence document

**Current State:**

- Fork simulation tools exist (`scripts/gov/simulate-hardhat.ts`)
- No documented Base Sepolia rehearsal
- No documented emergency/recovery drills

---

## 3. 🟠 Operational Runbooks (DOCS)

**Priority:** 🟠 **HIGH PRIORITY** - Strongly recommended before mainnet  
**Type:** Documentation  
**Estimated Time:** 4-6 hours  
**Source:** `docs/OUTSTANDING_ISSUES.md` #4

**What's Missing:**

- Detailed runbooks in `governance/runbooks/`
- Step-by-step emergency procedures
- Step-by-step recovery procedures
- Step-by-step standard change procedures
- Step-by-step slow change procedures

**Why Critical:**

- Required for operational readiness
- Enables team to respond to incidents
- Documents standard operating procedures
- Complements emergency drills

**Action Items:**

- [ ] Create `governance/runbooks/emergency.md` - Step-by-step emergency procedures
- [ ] Create `governance/runbooks/recovery.md` - Unpause and recovery procedures
- [ ] Create `governance/runbooks/standard-changes.md` - Bounded parameter updates
- [ ] Create `governance/runbooks/slow-changes.md` - Module swap procedures
- [ ] Link from `docs/EMERGENCY_POLICY.md`

**Current State:**

- `governance/runbooks/` directory exists but is empty
- `docs/EMERGENCY_POLICY.md` exists but is high-level policy, not operational runbook
- No step-by-step procedures for common operations

---

## 4. 🟠 AUDIT.md - Audit Documentation (DOCS)

**Priority:** 🟠 **HIGH PRIORITY** - Strongly recommended before mainnet  
**Type:** Documentation  
**Estimated Time:** 1-2 hours  
**Source:** `docs/OUTSTANDING_ISSUES.md` #2

**What's Missing:**

- `docs/AUDIT.md` file
- Audit status documentation (even if "not yet audited")
- Audit plan if audits are planned
- Scope list (contracts, commit hash)
- Links to audit reports when available
- Document fixes linked to commits

**Why Critical:**

- Expected by auditors and security researchers
- Documents audit readiness
- Provides scope for future audits
- Links security fixes to commits

**Action Items:**

- [ ] Create `docs/AUDIT.md` with audit status/plan
- [ ] Create audit package structure (optional but recommended)
- [ ] Document scope list (contracts to be audited)
- [ ] Link to `docs/SECURITY_MODEL.md` for invariants list
- [ ] Link to `docs/TECHNICAL_OVERVIEW.md` for architecture

**Current State:**

- No `docs/AUDIT.md` file exists
- No audit package directory
- No scope list documented
- Architecture overview exists (`docs/TECHNICAL_OVERVIEW.md`) but not in audit package format

---

## 5. 🟡 Fork Deployment Rehearsal (TEST/DOCS)

**Priority:** 🟡 **MUST-PASS GATE** - Required before mainnet  
**Type:** Testing + Documentation  
**Estimated Time:** 2-3 hours  
**Source:** `docs/OUTSTANDING_ISSUES.md` #8

**What's Missing:**

- Mainnet fork deployment rehearsal
- Documented rehearsal process
- Saved transaction hashes
- Verification that all contracts deploy correctly
- Verification that role assignments are correct

**Why Critical:**

- Must-pass gate for mainnet deployment
- Validates deployment scripts work on mainnet fork
- Identifies deployment issues before mainnet
- Provides evidence of readiness

**Action Items:**

- [ ] Perform mainnet fork deployment rehearsal
- [ ] Document rehearsal process
- [ ] Save transaction hashes
- [ ] Verify all contracts deploy correctly
- [ ] Verify role assignments correct
- [ ] Document in deployment docs

**Current State:**

- Fork simulation tools exist
- No documented mainnet fork deployment rehearsal
- No documented rehearsal with tx hashes

---

## Summary

| Priority | Item                        | Type      | Time    | Status     |
| -------- | --------------------------- | --------- | ------- | ---------- |
| 🔴 #1    | SECURITY.md                 | Docs      | 30 min  | ❌ Missing |
| 🟠 #2    | Emergency + Recovery Drills | Test/Docs | 2-4 hrs | ❌ Missing |
| 🟠 #3    | Operational Runbooks        | Docs      | 4-6 hrs | ❌ Missing |
| 🟠 #4    | AUDIT.md                    | Docs      | 1-2 hrs | ❌ Missing |
| 🟡 #5    | Fork Deployment Rehearsal   | Test/Docs | 2-3 hrs | ❌ Missing |

**Total Estimated Time:** 10-16 hours

---

## Additional High-Priority Items (Not in Top 5)

### 6. CHANGELOG.md (DOCS)

- **Priority:** High
- **Time:** 1 hour
- **Status:** Missing
- Create `CHANGELOG.md` following Keep a Changelog format

### 7. Slither Status Verification (TEST)

- **Priority:** Must-Pass Gate
- **Time:** 1 hour
- **Status:** Unknown
- Run slither locally, review findings, document exceptions

### 8. Verification Documentation (DOCS)

- **Priority:** High
- **Time:** 2-3 hours
- **Status:** Partial
- Enhance `scripts/verify.ts`, document verification process

### 9. Contract Security Tasks - Phase 1 (CODE)

- **Priority:** Critical (Security)
- **Time:** Week 1-2
- **Status:** Unchecked
- 9 security tasks from `docs/plans/CONTRACT_IMPROVEMENTS_DEVELOPMENT_PLAN.md`
- **Note:** May be deferred if not critical for MVP

### 10. Escalation Fee Transfer Verification (CODE/TEST)

- **Priority:** High
- **Time:** 4-6 hours
- **Status:** Needs Verification
- Verify fee transfer order, add missing events, test edge cases

---

## Recommended Execution Order

1. **SECURITY.md** (30 min) - Quick win, unblocks mainnet
2. **AUDIT.md** (1-2 hrs) - Quick documentation win
3. **CHANGELOG.md** (1 hr) - Quick documentation win
4. **Fork Deployment Rehearsal** (2-3 hrs) - Validates deployment
5. **Emergency + Recovery Drills** (2-4 hrs) - Validates operations
6. **Operational Runbooks** (4-6 hrs) - Documents procedures

**Total:** ~11-17 hours for top 6 items

---

## Notes

### Already Complete ✅

- SECURITY_MODEL.md - Comprehensive (570 lines)
- CI/CD Pipeline - Exists and working
- Repository Hygiene - Mostly complete (.nvmrc, .env.example, LICENSE)
- Governance Documentation - Comprehensive
- Testing - 277 passing tests
- Code Extraction - DecentralizedResolutionModule extracted
- Role Removal - ROLE_MODULE_DEVELOPER removed

### Context

- **Overall Progress:** ~70% complete (per MAINNET_CHECKLIST_ASSESSMENT.md)
- **Mainnet Readiness:** Close, but missing critical documentation and operational procedures
- **Security:** Strong foundation, but missing security contact/disclosure policy
- **Operations:** Tools exist, but procedures not documented

---

**Last Updated:** 2026-01-06  
**Next Review:** After completing top 5 priorities
