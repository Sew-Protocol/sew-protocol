### Legend: threats → controls (what the diagram is proving)

**1) UI / Operator manipulation (TB1)**

-   Threats: phishing, "wrong button", fake status, selective disclosure, coercive UX

-   Controls: UI is *never trusted*; only on-chain escrow state + rules matter; evidence is committed on-chain (hashes) rather than "screenshots in a UI".

**2) Buyer/Seller cheating**

-   Threats: false claims, non-delivery, delivery disputes, timing games

-   Controls: funds locked in immutable escrow; dispute lifecycle is explicit; outcomes enforceable by contract rules.

**3) Resolver collusion / bribery / non-performance (TB2)**

-   Threats: collusion, bribery, extortion, lazy/no-response, spam disputes

-   Controls: bonded stake requirement; assignment + deadline; slashing + freeze; re-eligibility only after top-up; plurality of resolvers.

**4) Governance capture / retroactive change (TB3)**

-   Threats: hostile takeover, "upgrade to steal funds", rule changes mid-escrow

-   Controls: all contracts immutable; governance can only *swap modules/templates for NEW escrows*; existing escrows remain under original rules (no rewriting history).

**5) Yield / external dependency risk (TB4)**

-   Threats: yield protocol exploit, liquidity failures, accounting mismatch

-   Controls: yield is optional and bounded; escrow accounting remains authoritative; yield cannot change dispute outcomes or custody rules.