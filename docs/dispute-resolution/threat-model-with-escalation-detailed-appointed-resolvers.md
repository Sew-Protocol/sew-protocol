flowchart TB
  subgraph Actors[Actors (Untrusted)]
    B[Buyer]
    S[Seller]
    UI[UI/Clients (untrusted)]
  end

  subgraph Court[SEW Court Core (On-chain, Enforced)]
    ESC[Escrow (Immutable)\nstate + funds]
    DIS[Dispute Engine\nopen/assign/decide/appeal]
    EVI[Evidence Commitments\nhash/attest]
    FIN[Finality + Transfers\nno override]
    PATH[Escalation Path\nsnapshotted per escrow]
  end

  subgraph Pools[Appointed Resolver Pools (Permissioned)]
    RPOOL[Tier 1 Resolver Pool\nappointed]
    SPOOL[Tier 2 Senior Pool\nappointed]
  end

  subgraph Econ[Economic Security]
    ST1[T1 Bonds]
    ST2[T2 Bonds]
    SL1[Slash/Freeze T1\n(timeout/misbehavior)]
    SL2[Slash/Freeze T2\n(timeout/misbehavior)]
  end

  subgraph Ext[Tier 3 External Court]
    K[Kleros Adapter\n(last resort)]
  end

  subgraph Gov[Slow-Lane Governance (Non-retroactive)]
    DAO[DAO]
    CFG[Policy Config\n(appeal windows, timeouts,\nthresholds, Kleros params)]
    REG[Template Registry\nfor NEW escrows]
  end

  B --> UI --> ESC
  S --> UI --> ESC
  ESC --> DIS
  ESC --> EVI
  DIS --> FIN

  DAO --> CFG --> REG --> PATH
  PATH -->|snapshotted at creation| ESC

  DIS -->|assign T1 single| RPOOL --> DIS
  RPOOL --> ST1
  DIS --> SL1 --> RPOOL

  DIS -->|loser appeals| SPOOL --> DIS
  SPOOL --> ST2
  DIS --> SL2 --> SPOOL

  DIS -->|loser appeals| K --> DIS

