# Forge Trace Fixtures

These JSON files are the **golden traces** used by `TraceEquivalenceTest` and `TraceRegressionTest` to verify that the EVM implementation matches the Clojure simulation.

## Schema

The canonical fixture format is formally specified by:
```
test/foundry/traces/schema/trace-fixture.v1.schema.json
```
(JSON Schema draft-07.)  `schema_version` is locked to `"1"`.  Any breaking change to the format requires a new schema version and a migration note here.

## File Naming

- `trace_<scenario_id>.json` — Forge fixture, consumed by `TraceEquivalence.t.sol`
- `trace_phase_z_<id>.json` — Phase Z adversarial traces (liveness failures, cascades)
- `scenario_<scenario_id>.json` — (optional) Clojure scenario input that generates the trace
- `regression/` — Auto-populated by `clojure -M:trace-regress` from the scored trace store

## Trace Format

```json
{
  "schema_version": "1",
  "scenario_id": "create_release",
  "description": "...",
  "phase": "Z",
  "trace_score": 5,
  "categories": ["liveness-fail"],
  "fee_bps": 100,
  "step_count": 2,
  "steps": [
    {
      "seq": 0,
      "action": "create_escrow",
      "caller_role": "buyer",
      "warp_to": 1001,
      "save_wf_as": "wf0",
      "params": {
        "to_role": "seller",
        "amount": 10000000000000000000000
      },
      "expected": {
        "escrow_state": 1,
        "amount_after_fee": 9900000000000000000000,
        "total_held": 9900000000000000000000,
        "total_fees": 100000000000000000000,
        "pending_settlement_exists": false,
        "dispute_level": 0
      }
    }
  ]
}
```

### Metadata fields (optional, non-functional)

| Field         | Type     | Description |
|---------------|----------|-------------|
| `phase`       | string   | Simulation phase label (e.g. `"Z"`) |
| `trace_score` | number   | `attacker-profit + 10×invariant-violations + 5×liveness-failure` |
| `categories`  | string[] | `top-profitable`, `liveness-fail`, `cascade`, `abnormal-slash` |

## EscrowState Enum

| Value | Name     |
|-------|----------|
| 0     | NONE     |
| 1     | PENDING  |
| 2     | RELEASED |
| 3     | REFUNDED |
| 4     | DISPUTED |
| 5     | RESOLVED |

## Roles

| Role       | Address                                    |
|------------|--------------------------------------------|
| `buyer`    | `0x0000000000000000000000000000000000001001` |
| `seller`   | `0x0000000000000000000000000000000000001002` |
| `resolver` | `0x0000000000000000000000000000000000001234` |

## Supported Actions

| Action                         | Caller       | Notes                                          |
|--------------------------------|--------------|------------------------------------------------|
| `create_escrow`                | buyer        | params: `to_role`, `amount`                    |
| `release`                      | buyer        | sender releases to recipient                   |
| `sender_cancel`                | buyer        | sender requests cancel                         |
| `recipient_cancel`             | seller       | recipient requests cancel                      |
| `raise_dispute`                | buyer/seller | either party can raise                         |
| `release_as_dispute_resolver`  | resolver     | resolver decides for recipient                 |
| `cancel_as_dispute_resolver`   | resolver     | resolver decides for sender                    |
| `execute_pending_settlement`   | anyone       | after appeal window expires                    |
| `auto_cancel_disputed`         | anyone       | after `maxDisputeDuration` (90 days in vault)  |

## Phase Z Traces

Phase Z adversarial scenarios map macro-level legitimacy risks to EVM liveness failures:

| File | Phase Z test | EVM behaviour | trace_score |
|------|-------------|---------------|-------------|
| `trace_phase_z_liveness.json` | TEST 2 (market shock) | dispute → resolver absent → auto-cancel after 90 days | 5 |

Generate more Phase Z traces:
```bash
cd sew-simulation
clojure -M:phase-z-persist         # run, score, persist top 1%
clojure -M:trace-regress            # promote persisted → test/foundry/traces/regression/
```

## Generating Traces from Clojure

```bash
cd sew-simulation
clojure -M:trace-export \
  test/foundry/traces/scenario_create_release.json \
  ../sew-protocol/test/foundry/traces/trace_create_release.json
```

The Clojure exporter lives at:
`src/resolver_sim/io/trace_export.clj`


```json
{
  "schema_version": "1",
  "scenario_id": "create_release",
  "description": "...",
  "fee_bps": 100,
  "step_count": 2,
  "steps": [
    {
      "seq": 0,
      "action": "create_escrow",
      "caller_role": "buyer",
      "warp_to": 1001,
      "save_wf_as": "wf0",
      "params": {
        "to_role": "seller",
        "amount": 10000000000000000000000
      },
      "expected": {
        "escrow_state": 1,
        "amount_after_fee": 9900000000000000000000,
        "total_held": 9900000000000000000000,
        "total_fees": 100000000000000000000,
        "pending_settlement_exists": false,
        "dispute_level": 0
      }
    }
  ]
}
```

## EscrowState Enum

| Value | Name     |
|-------|----------|
| 0     | NONE     |
| 1     | PENDING  |
| 2     | RELEASED |
| 3     | REFUNDED |
| 4     | DISPUTED |
| 5     | RESOLVED |

## Roles

| Role       | Address                                    |
|------------|--------------------------------------------|
| `buyer`    | `0x0000000000000000000000000000000000001001` |
| `seller`   | `0x0000000000000000000000000000000000001002` |
| `resolver` | `0x0000000000000000000000000000000000001234` |

## Supported Actions

| Action                       | Caller       | Notes                            |
|------------------------------|--------------|----------------------------------|
| `create_escrow`              | buyer        | params: `to_role`, `amount`      |
| `release`                    | buyer        | sender releases to recipient     |
| `sender_cancel`              | buyer        | sender requests cancel           |
| `recipient_cancel`           | seller       | recipient requests cancel        |
| `raise_dispute`              | buyer/seller | either party can raise           |
| `release_as_dispute_resolver`| resolver     | resolver decides for recipient   |
| `cancel_as_dispute_resolver` | resolver     | resolver decides for sender      |
| `execute_pending_settlement` | anyone       | after appeal window expires      |
| `auto_cancel_disputed`       | anyone       | after 90-day dispute timeout     |

## Generating Traces from Clojure

```bash
cd sew-simulation
clojure -M:trace-export \
  test/foundry/traces/scenario_create_release.json \
  ../sew-protocol/test/foundry/traces/trace_create_release.json
```

The Clojure exporter lives at:
`src/resolver_sim/io/trace_export.clj`
