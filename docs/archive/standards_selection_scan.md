### Approach

-   Add one lightweight "standards scan" gate to each phase: analysis → design → review, tuned for speed (Cursor-friendly).

-   Provide a small, repeatable checklist + prompt templates that reliably surface things like ERC-4626 before you commit to bespoke plumbing.

-   Suggest a tiny "standards map" file + CI hook so it becomes muscle memory without process bloat.

A practical "standards fit" loop (that would have caught ERC-4626)
------------------------------------------------------------------

You want something that triggers when you're about to invent:

-   receipt tokens / share accounting

-   deposit/withdraw semantics

-   yield-bearing wrappers (aToken/cToken/etc.)

-   adapters across protocols

Those are exactly the situations where ERCs/EIPs and "de facto standards" (OZ/Solmate interfaces) usually exist.

### 1) Add a 5-minute Standards Scan step to Analysis

Make it a required section in every analysis note / issue / PR description:

**Standards Scan (required)**

-   What is the *core primitive* we are building? (e.g., "tokenized vault wrapping yield source")

-   What interfaces already encode that primitive? (ERC-20 / ERC-4626 / ERC-3156 / ERC-2612 / ERC-1271 / ERC-4337 / etc.)

-   If we *don't* use a standard, why not? (1--2 bullets: "not supported by protocol", "adds size", "semantics mismatch", "audit risk")

Cursor prompt (paste into your analysis template):

-   "Given this feature description, list any ERC/EIP or widely-used interface standards that match the same primitive. For each: why it fits, what we'd gain/lose, and the smallest adoption path."

**Trigger words** that should force this section:

-   shares, vault, wrapper, receipt token, yield, deposit/withdraw, adapter, module, router, registry, permit, signature, replay, nonce.

### 2) Design: a "Decision table" that compares Standard vs Custom

In your design doc (even if it's just a Markdown note), include a tiny table:

-   Option A: Adopt standard (e.g. ERC-4626)

-   Option B: Internal interface "ERC-4626-like"

-   Option C: Bespoke implementation

For each option, score quickly (1--3) on:

-   integration speed

-   correctness/auditability

-   bytecode size impact

-   upgrade flexibility

-   ecosystem composability (future yield modules)

This would have made "we're connecting to a vault" naturally point to ERC-4626 as the baseline.

Cursor prompt for design:

-   "Create a decision table: Standard vs Minimal Adapter vs Custom. Highlight which functions/storage are eliminated from BaseEscrow if we adopt the standard."

### 3) Review: enforce "Are we reinventing a standard?" as a PR gate

In code review / PR template, add 3 checkboxes:

-   Standards Scan section completed

-   If not using a standard: explicit reason + link to alternative

-   Interfaces named to match standard semantics (even if not fully compliant)

Then teach Cursor to *block approval* until the section is present.

Cursor prompt for review:

-   "Review this diff and identify any areas that look like an existing ERC/EIP interface (vaults, permits, signatures, batching, meta-tx). If so, recommend the closest standard and the minimum refactor to align."

Make it easy: maintain a "Standards Map" for your protocol
----------------------------------------------------------

Create a small file in-repo that's fast to scan and keeps institutional memory:

`/docs/standards-map.md` (example sections)

-   Yield / Vaults: ERC-4626

-   Permits: ERC-2612 (EIP-2612), Permit2 (if you ever use it)

-   Signatures: ERC-1271

-   Meta-tx / account abstraction: ERC-4337, ERC-6900 / 7579 (if applicable)

-   Security patterns: EIP-712 typed data, reentrancy patterns, etc.

For each, include:

-   "When it applies" (1 line)

-   "Why we use it / why we don't"

-   "Local interfaces impacted"

This reduces the chance of "we described it as a vault, but didn't think of 4626".

Optional but powerful: a tiny CI / lint hook
--------------------------------------------

Without heavy tooling, you can add a simple CI check that fails if PR description (or a Markdown file in the PR) is missing the "Standards Scan" header.

If you don't want CI, a lightweight alternative is:

-   a GitHub PR template section

-   Cursor local checklist that it auto-inserts into new issues/PRs

Why this works in practice
--------------------------

ERC-4626 is easy to miss because teams think in "protocol-specific terms" (aToken, scaled balance) rather than "primitive terms" (tokenized vault). The fix is to force the *primitive naming* early, then do a quick "what ERC matches this primitive?" scan.

* * * * *

### Assumptions

-   You have (or can add) lightweight templates for issues/PRs/design notes in your repo.

-   You're okay adding a small amount of process if it prevents big refactors and size regressions.

-   Cursor is a primary workflow tool for analysis + implementation + review.

### Next steps

-   Add **Standards Scan** to your issue template + PR template today.

-   Create `/docs/standards-map.md` and seed it with the handful of standards you already rely on (AccessControl patterns, signature standards, vaults).

-   Add a one-line rule: "If you invent 'shares/receipt token/vault', you must justify not using ERC-4626."






### Further details, aimed at cursor

A practical "standards fit" loop (that would have caught ERC-4626)
------------------------------------------------------------------

You want something that triggers when you're about to invent:

-   receipt tokens / share accounting

-   deposit/withdraw semantics

-   yield-bearing wrappers (aToken/cToken/etc.)

-   adapters across protocols

Those are exactly the situations where ERCs/EIPs and "de facto standards" (OZ/Solmate interfaces) usually exist.

### 1) Add a 5-minute Standards Scan step to Analysis

Make it a required section in every analysis note / issue / PR description:

**Standards Scan (required)**

-   What is the *core primitive* we are building? (e.g., "tokenized vault wrapping yield source")

-   What interfaces already encode that primitive? (ERC-20 / ERC-4626 / ERC-3156 / ERC-2612 / ERC-1271 / ERC-4337 / etc.)

-   If we *don't* use a standard, why not? (1--2 bullets: "not supported by protocol", "adds size", "semantics mismatch", "audit risk")

Cursor prompt (paste into your analysis template):

-   "Given this feature description, list any ERC/EIP or widely-used interface standards that match the same primitive. For each: why it fits, what we'd gain/lose, and the smallest adoption path."

**Trigger words** that should force this section:

-   shares, vault, wrapper, receipt token, yield, deposit/withdraw, adapter, module, router, registry, permit, signature, replay, nonce.

### 2) Design: a "Decision table" that compares Standard vs Custom

In your design doc (even if it's just a Markdown note), include a tiny table:

-   Option A: Adopt standard (e.g. ERC-4626)

-   Option B: Internal interface "ERC-4626-like"

-   Option C: Bespoke implementation

For each option, score quickly (1--3) on:

-   integration speed

-   correctness/auditability

-   bytecode size impact

-   upgrade flexibility

-   ecosystem composability (future yield modules)

This would have made "we're connecting to a vault" naturally point to ERC-4626 as the baseline.

Cursor prompt for design:

-   "Create a decision table: Standard vs Minimal Adapter vs Custom. Highlight which functions/storage are eliminated from BaseEscrow if we adopt the standard."

### 3) Review: enforce "Are we reinventing a standard?" as a PR gate

In code review / PR template, add 3 checkboxes:

-   Standards Scan section completed

-   If not using a standard: explicit reason + link to alternative

-   Interfaces named to match standard semantics (even if not fully compliant)

Then teach Cursor to *block approval* until the section is present.

Cursor prompt for review:

-   "Review this diff and identify any areas that look like an existing ERC/EIP interface (vaults, permits, signatures, batching, meta-tx). If so, recommend the closest standard and the minimum refactor to align."

Make it easy: maintain a "Standards Map" for your protocol
----------------------------------------------------------

Create a small file in-repo that's fast to scan and keeps institutional memory:

`/docs/standards-map.md` (example sections)

-   Yield / Vaults: ERC-4626

-   Permits: ERC-2612 (EIP-2612), Permit2 (if you ever use it)

-   Signatures: ERC-1271

-   Meta-tx / account abstraction: ERC-4337, ERC-6900 / 7579 (if applicable)

-   Security patterns: EIP-712 typed data, reentrancy patterns, etc.

For each, include:

-   "When it applies" (1 line)

-   "Why we use it / why we don't"

-   "Local interfaces impacted"

This reduces the chance of "we described it as a vault, but didn't think of 4626".

Optional but powerful: a tiny CI / lint hook
--------------------------------------------

Without heavy tooling, you can add a simple CI check that fails if PR description (or a Markdown file in the PR) is missing the "Standards Scan" header.

If you don't want CI, a lightweight alternative is:

-   a GitHub PR template section

-   Cursor local checklist that it auto-inserts into new issues/PRs

Why this works in practice
--------------------------

ERC-4626 is easy to miss because teams think in "protocol-specific terms" (aToken, scaled balance) rather than "primitive terms" (tokenized vault). The fix is to force the *primitive naming* early, then do a quick "what ERC matches this primitive?" scan.
