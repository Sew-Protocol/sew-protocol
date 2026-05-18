Kleros Backstop Checklist
1. Authority & Access Control
Arbitrator authorization
    • Only the configured arbitrator can invoke rule(...). 
    • Arbitrator address is immutable per escrow or snapshotted at dispute creation. 
    • Governance cannot retroactively swap arbitrator for active disputes. 
    • Unauthorized callers cannot trigger propagation paths. 
    • Replay protection exists for repeated ruling delivery. 
Resolver authority boundaries
    • releaseAsDisputeResolver(...) is callable only by authorized dispute modules. 
    • cancelAsDisputeResolver(...) is callable only by authorized dispute modules. 
    • Escrow cannot be resolved by arbitrary external contracts. 
    • Manual recovery paths have strict authorization gating. 
    • Emergency/manual override paths are auditable and event-emitting. 

2. Ruling Semantics
Ruling correctness
    • Ruling 1 deterministically maps to release. 
    • Ruling 2 deterministically maps to cancel/refund. 
    • Invalid rulings revert or enter explicit safe-failure handling. 
    • Unknown ruling values cannot silently default to sender or recipient. 
    • Duplicate rulings cannot create double settlement. 
Resolution determinism
    • Same ruling + same escrow state always produces same outcome. 
    • Propagation logic is independent of transient governance state. 
    • Resolution behavior is stable across retries/replays. 

3. Propagation Safety
Failure isolation
    • try/catch fully isolates propagation failures. 
    • Arbitrator callback cannot brick escrow permanently. 
    • Failed propagation emits structured failure events. 
    • Retry path exists after propagation failure. 
    • Retry path is permissioned appropriately. 
Idempotency
    • Re-running propagation after partial failure is safe. 
    • Escrow cannot be credited twice via repeated propagation. 
    • Claimable balances cannot be over-credited. 
    • Settlement execution is single-finalization only. 
Reentrancy
    • Propagation paths are protected against reentrancy. 
    • Claim crediting occurs before external calls where applicable. 
    • No external token callback can alter dispute outcome mid-propagation. 

4. Pull-Settlement Guarantees
No automatic payout
    • Arbitrator rulings never directly transfer escrow funds externally. 
    • Resolution only mutates state and/or claimable ledger balances. 
    • Users must explicitly withdraw funds themselves. 
    • No ERC20 settlement path performs direct recipient push. 
    • No ETH settlement path bypasses claimable accounting. 
Claim accounting integrity
    • Claimable balances are conserved. 
    • Total credited balances cannot exceed escrowed assets. 
    • Withdrawals are bounded by credited entitlement. 
    • Settlement cannot create negative accounting states. 

5. Liveness & Recovery
Backstop liveness
    • Escrow can still resolve if automated propagation fails. 
    • Manual propagation path is tested. 
    • Recovery path works after arbitrator callback gas exhaustion. 
    • Recovery path works after downstream module revert. 
    • Recovery path works after temporary pause/unpause cycles. 
Timeout handling
    • Arbitration timeout semantics are explicit. 
    • Unresolved disputes cannot become permanently frozen unintentionally. 
    • Timeout outcome is policy-defined rather than implicit fallback. 
    • Timeout paths do not bypass pull-settlement guarantees. 

6. Escalation & Appeals
Appeal integrity
    • Appeal status prevents premature propagation. 
    • Lower-tier ruling cannot finalize while higher-tier appeal is active. 
    • Appeal transitions are deterministic. 
    • Final ruling source is unambiguous. 
Kleros backstop correctness
    • Escalation to Kleros is irreversible once accepted. 
    • Intermediate resolver cannot overwrite finalized Kleros ruling. 
    • Backstop propagation cannot conflict with earlier local rulings. 
    • Escrow state machine enforces single canonical final outcome. 

7. Governance Risk Containment
Governance isolation
    • Governance cannot seize escrowed funds. 
    • Governance cannot rewrite active dispute outcomes. 
    • Governance cannot change active dispute resolution modules. 
    • Governance pause cannot silently finalize disputes. 
Emergency controls
    • Emergency pause preserves withdrawal safety. 
    • Emergency pause preserves claimable balances. 
    • Emergency pause cannot create inconsistent settlement state. 

8. Adversarial & Economic Testing
Replay/flooding
    • Repeated propagation attempts cannot grief escrow. 
    • Invalid ruling spam cannot lock settlement. 
    • Gas griefing on propagation is bounded. 
Incentive checks
    • Resolver cannot profit from propagation failure. 
    • User cannot gain additional funds from retry mechanics. 
    • Escalation incentives remain economically coherent after propagation failure. 
Simulation coverage
    • Propagation failure scenarios included in adversarial simulator. 
    • Retry-after-failure traces exist. 
    • Appeal-while-timeout scenarios exist. 
    • Governance-pause-during-propagation scenarios exist. 
    • Cross-module revert propagation traces exist. 

9. Eventing & Auditability
Observability
    • All rulings emit events. 
    • All propagation attempts emit events. 
    • Failed propagation emits structured reason metadata where feasible. 
    • Manual recovery execution emits events. 
    • Final settlement state is externally reconstructable from logs. 

10. High-Value Additional Checks
These are especially valuable for Sew’s architecture.
Strong recommendations
    • Add invariant: “No dispute resolution path performs direct external escrow payout.” 
    • Add invariant: “At most one terminal settlement may execute.” 
    • Add invariant: “Propagation retry cannot change economic outcome.” 
    • Add invariant: “Kleros ruling replay is idempotent.” 
    • Add invariant: “Governance changes affect only future disputes.” 
Very high-value simulation scenarios
    • Kleros callback revert storm. 
    • Partial propagation success + retry. 
    • Escalation during pause. 
    • Same-block appeal + propagation race. 
    • Delayed arbitrator callback after local timeout. 
    • Resolver replacement during active escalation. 
    • Manual propagation after failed automated propagation. 
    • Claim withdrawal racing with propagation retry.

