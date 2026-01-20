stateDiagram-v2
direction TB

[*] --> NoDispute: Escrow created (immutable rules)\nPath snapshotted

NoDispute --> Active: Funds locked / performance ongoing

Active --> DisputeOpen: Party opens dispute\n(evidence commitments submitted)
DisputeOpen --> T1_Assigned: Assign appointed Resolver (single)\nstart T1 deadline

T1_Assigned --> T1_Decided: Resolver decision committed\n(winner/loser identified)
T1_Assigned --> T1_Timeout: Deadline missed\nslash/freeze resolver

T1_Timeout --> T1_Assigned: Reassign new appointed resolver (single)\n(optional loop)
T1_Timeout --> T2_Assigned: Optional escalate after repeated failures\n(policy)

T1_Decided --> Finalized: No appeal within window\nfinalize outcome (on-chain transfer)

T1_Decided --> T2_Assigned: Losing party appeals within window\nAssign appointed Senior Resolver (single)\nstart T2 deadline

T2_Assigned --> T2_Decided: Senior decision committed\n(winner/loser identified)
T2_Assigned --> T2_Timeout: Deadline missed\nslash/freeze senior

T2_Timeout --> T2_Assigned: Reassign new appointed senior (single)\n(optional loop)
T2_Timeout --> Kleros: Optional escalate after repeated failures\n(policy)

T2_Decided --> Finalized: No appeal within window\nfinalize outcome (on-chain transfer)

T2_Decided --> Kleros: Losing party appeals within window\nKleros adapter invoked

Kleros --> KlerosRuling: Ruling received / committed
KlerosRuling --> Finalized: Finalize outcome (on-chain transfer)

Finalized --> [*]
