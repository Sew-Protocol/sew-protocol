# Security & Architectural Principles Checklist

This document defines the "Hard Rules" for the multi-escrow protocol. Any Pull Request or Architectural change must be verified against this checklist.

## 1. Non-Custodial Integrity
- [ ] **No Custody Addresses:** The protocol must never have a "Treasury," "Recovery Wallet," or "Insurance Fund" address that can receive user principal or yield-in-progress during emergency operations.
- [ ] **Direct-to-Source:** Emergency functions must only move funds back to the original Escrow Vault or the User's wallet.
- [ ] **No Global Sweeps:** There shall be no `recoverERC20` or `sweep` functions in any contract that holds user funds (Vault, EscrowableERC20).
- [ ] **Guardian Limits:** Guardians can *stop* things (Pause, Disable Module, Lower Caps) but never *move* or *redirect* user funds to new recipients.

## 2. Module Resilience (Anti-Bricking)
- [ ] **Fail-Open Withdrawals:** Core escrow functions (`release`, `cancel`, `dispute`) must not brick if a Module reverts.
- [ ] **Try-Catch Integration:** All external calls to Yield or Resolution modules must be wrapped in `try/catch` or low-level `call` patterns with a fallback path that allows the user to recover their principal.
- [ ] **State Independence:** The "Truth" of an escrow (who owes what) must reside in the Vault's state, not the Module's state. Modules should be treated as "Sidecars" that can be detached without losing the core escrow balance.

## 3. Privilege Least Authority
- [ ] **Function-Level Gating:** Governance roles (Timelock vs. Guardian) must be strictly separated. Guardians manage "Fast" safety; Timelock manages "Slow" structural changes.
- [ ] **No "God Mode":** No single role should have the power to both Pause the system AND move funds.

## 4. Multi-Currency Safety
- [ ] **Decimal Neutrality:** Calculations must never assume 18 decimals.
- [ ] **Dust/Deficit Boundaries:** Any accounting "Cleanup" logic must have hardcoded upper bounds (e.g., 5 wei) to ensure significant funds are never absorbed by the protocol.
