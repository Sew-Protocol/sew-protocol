flowchart TB
  %% =========================
  %% SEW Protocol = Cryptographic Court (Escalation Path)
  %% resolver -> senior resolver -> kleros
  %% governance adjusts path for NEW escrows only
  %% =========================

  %% ---- Actors / Clients ----
  subgraph Actors[Actors (Untrusted)]
    B[Buyer]
    S[Seller]
    UI[Wallet / Marketplace UI<br/>(untrusted client)]
    O[Operators / Frontends<br/>(untrusted)]
  end

  %% ---- Court Core (On-chain) ----
  subgraph Court[SEW Court Core (On-chain, Enforced)]
    ESC[Escrow Contract (Immutable)<br/>Per-workflow state machine]
    RULES[Outcome Rules (Immutable)<br/>release/refund/resolve]
    DISPUTE[Dispute Lifecycle<br/>open → assign → decide → finalize]
    EVID[Evidence Commitments<br/>(hashes / attestations)]
    PATH[Escalation Path Selector<br/>(configured at escrow creation)]
  end

  %% ---- Tier 1: Resolver ----
  subgraph T1[Tier 1 (Bonded Resolver)]
    RPOOL[Resolver Pool]
    R[Assigned Resolver (single)]
    STAKE1[Stake Ledger]
    SLASH1[Slash/Freeze<br/>(deadline / misbehavior)]
    REP1[Eligibility / Reputation<br/>(re-eligible after top-up)]
  end

  %% ---- Tier 2: Senior Resolver ----
  subgraph T2[Tier 2 (Bonded Senior Resolver)]
    SPOOL[Senior Resolver Pool]
    SR[Assigned Senior Resolver (single)]
    STAKE2[Senior Stake Ledger]
    SLASH2[Senior Slash/Freeze<br/>(deadline / misbehavior)]
    REP2[Senior Eligibility]
  end

  %% ---- Tier 3: External Court ----
  subgraph T3[Tier 3 (External Court)]
    K[Kleros (external arbitration)]
  end

  %% ---- Governance (Non-retroactive) ----
  subgraph GOV[Governance (Slow Lane, Non-retroactive)]
    DAO[DAO / Governance Authority<br/>(slow lane)]
    REG[Registry / Templates<br/>for NEW escrows]
    CFG[Escalation Policy Config<br/>(tiers, timeouts, thresholds)]
  end

  %% ---- Trust Boundaries ----
  TB1((Trust Boundary:<br/>UI / Off-chain))
  TB2((Trust Boundary:<br/>Tier 1 decision))
  TB3((Trust Boundary:<br/>Tier 2 decision))
  TB4((Trust Boundary:<br/>External court))
  TB5((Trust Boundary:<br/>Governance changes))

  %% ---- Main flows (creation/use) ----
  B --> UI --> ESC
  S --> UI --> ESC
  ESC --> EVID
  ESC --> DISPUTE
  ESC --> RULES

  %% ---- Escalation path config at creation ----
  DAO --> REG --> CFG
  CFG -->|new escrow templates only| PATH
  PATH -->|snapshotted into escrow| ESC

  %% ---- Dispute assignment: Tier 1 ----
  DISPUTE -->|assign Tier 1| RPOOL --> R
  R -->|must be bonded| STAKE1
  DISPUTE -->|deadline/liveness| SLASH1 --> REP1 --> RPOOL
  R -->|decision commitment| DISPUTE

  %% ---- Escalation decision (from Tier 1) ----
  DISPUTE -->|escalate if needed| SR

  %% ---- Tier 2 assignment ----
  DISPUTE -->|assign Tier 2| SPOOL --> SR
  SR -->|must be bonded| STAKE2
  DISPUTE -->|deadline/liveness| SLASH2 --> REP2 --> SPOOL
  SR -->|decision commitment| DISPUTE

  %% ---- Escalation to Kleros ----
  DISPUTE -->|final escalation| K
  K -->|ruling / outcome data| DISPUTE

  %% ---- Finalization ----
  DISPUTE -->|finalize outcome| RULES -->|enforced transfer| ESC

  %% ---- Boundary links ----
  TB1 --- UI
  TB1 --- O
  TB2 --- R
  TB3 --- SR
  TB4 --- K
  TB5 --- DAO
  TB5 --- CFG
