# Security Policy

**Last Updated:** 2026-01-06  
**Version:** 1.0

---

## Security Contact

**Primary Contact:** security@[DOMAIN]  
**PGP Key:** [To be added]  
**Response Time:** We aim to respond to security reports within 48 hours.

---

## Responsible Disclosure Policy

We take security vulnerabilities seriously. If you discover a security vulnerability, we appreciate your help in disclosing it to us in a responsible manner.

### Reporting Process

1. **Do NOT** open a public GitHub issue for security vulnerabilities
2. **Email** your findings to: security@[DOMAIN]
3. **Include** the following information:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)
   - Your contact information (optional, for coordination)

### Disclosure Timeline

We follow a **90-day coordinated disclosure** policy:

- **Day 0:** Vulnerability reported
- **Day 0-7:** Initial triage and acknowledgment
- **Day 7-90:** Investigation, fix development, and testing
- **Day 90:** Public disclosure (or earlier if mutually agreed)

**Exceptions:**

- If the vulnerability is already publicly known, we may accelerate disclosure
- If the vulnerability is actively being exploited, we may disclose immediately
- If a fix is deployed and tested, we may disclose earlier

### Scope

**In Scope:**

- Smart contract vulnerabilities
- Access control issues
- Reentrancy vulnerabilities
- Logic errors in escrow state machine
- Governance manipulation vulnerabilities
- Economic attacks (flash loans, MEV, etc.)

**Out of Scope:**

- Frontend vulnerabilities
- Social engineering
- Physical security
- Denial of service (unless it leads to fund loss)
- Issues in third-party dependencies (Aave, etc.) - report to those projects

### Bounty Program

We do not currently operate a formal bug bounty program. However, we may offer rewards for critical vulnerabilities on a case-by-case basis.

---

## Security Best Practices

### For Users

- **Verify contract addresses** before interacting with the protocol
- **Use official interfaces** and verified contracts on block explorers
- **Review transaction details** carefully before signing
- **Never share private keys** or seed phrases
- **Be cautious** of phishing attempts

### For Developers

- **Review code** before deploying
- **Test thoroughly** on testnets before mainnet
- **Follow security best practices** (checks-effects-interactions, access control, etc.)
- **Keep dependencies updated**
- **Run static analysis** tools (Slither, Mythril)

---

## Security Resources

- **Security Model:** See [`docs/SECURITY_MODEL.md`](docs/SECURITY_MODEL.md) for detailed security assumptions and threat model
- **Governance Security:** See [`docs/governance.md`](docs/governance.md) for governance security model
- **Audit Status:** See [`docs/AUDIT.md`](docs/AUDIT.md) for audit information

---

## Incident Response

In the event of a security incident:

1. **Immediate Actions:**
   - Guardian can pause the protocol if needed
   - Emergency procedures documented in `governance/runbooks/emergency.md`

2. **Communication:**
   - We will communicate transparently about any security incidents
   - Updates will be posted on official channels

3. **Recovery:**
   - Recovery procedures documented in `governance/runbooks/recovery.md`
   - All recovery actions require timelock governance

---

## Acknowledgments

We thank security researchers who responsibly disclose vulnerabilities. Contributors will be acknowledged (with permission) in security advisories.

---

**Note:** This policy may be updated. Please check this file for the latest version.
