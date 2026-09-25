# Retained Aderyn report snapshots

This directory keeps **evidence-bearing** Aderyn runs that were previously only
referenced by a SHA-256 hash of an ephemeral, gitignored `report.md`. Retaining the
actual artifact (rather than only a hash of a vanished local file) lets the
historical repair lineage be reconstructed from two retained reports instead of one
retained report and one hash pointing at a file that no longer exists.

The transient default output `report.md` remains gitignored; only deliberately
retained runs are copied here, one per snapshot with a sidecar note.

## Report snapshots

| File | Date | Source revision (commit) | JJ revision | Aderyn | Config | SHA-256 |
| --- | --- | --- | --- | --- | --- | --- |
| `report-2026-09-23-96600050.md` | 2026-09-23 | `96600050` | `yqrpxzvv` | 0.6.8 | `aderyn.toml` (production scope) | `0ccfb6715f53f3be6e2e67b55792adc0658f73890f97023a7aaa77960a639e21` |

## Snapshot metadata: `report-2026-09-23-96600050.md`

```text
source revision : 96600050...
JJ revision     : yqrpxzvv
Aderyn          : 0.6.8
configuration   : aderyn.toml
report SHA-256  : 0ccfb6715f53f3be6e2e67b55792adc0658f73890f97023a7aaa77960a639e21
scope           : production configured scope
```

This runs corresponds to the current documented baseline in
[`docs/security/ADERYN_FINDINGS.md`](../../security/ADERYN_FINDINGS.md) (7 high,
19 low, 111 production-scoped Solidity files, 14,417 nSLOC). It is a snapshot of the
**current candidate source**, not the February deployment, and not the archived
pre-25-January report (see [`docs/security/SOLIDITY_STABILITY_STATEMENT.md`](../../security/SOLIDITY_STABILITY_STATEMENT.md)).
