# Sew Full Appeal profile

**Profile:** `sew-full-appeal`

**Artifact package:** `@sew/deployables@0.2.0`
**Current remediation candidate:** the source revision and artifact root recorded in its export manifest (independent review pending).

This profile covers the Sew escrow with internal resolver appeals and
BondLedger-backed appeal-bond custody. The 20-artifact allowlist is the
deployment boundary; it is not a qualification of every optional capability
present in the wider repository.

## Included capability

- Escrow creation, dispute, settlement, and withdrawal through `EscrowVault`.
- Internal DRM resolver rounds and appeal transitions.
- Appeal bond custody and disposition through `BondLedger` and
  `ResolverIncentiveModuleV2BondLedger`.
- The listed linked libraries, registry, creation policy, token registry, and
  governance timelock artifact.

## Explicit exclusions

| Capability | Excluded components | Profile requirement |
|---|---|---|
| External arbitration | `KlerosArbitrableProxy` and Kleros arbitration deployment/configuration | Do not configure an external resolver or claim Kleros qualification. External arbitration requires a separate profile with proxy, arbitrator, fee, callback, timeout, and runtime-pin qualification. |
| DR v3 resolver economics | `ResolverStakingModule`, `ResolverSlashingModule`, and `InsurancePoolVault` | Do not enable staking-backed capacity or slashing. Mixed-token exposure is unsupported; vindication receivables have no funded redemption path. Qualify these as a separate DR v3 profile. |
| Yield custody | Aave and other yield modules | Do not enable yield deposits. Yield-backed custody and recovery need a separate profile and adversarial qualification. |
| PRF adjudication | PRF contracts and independently verifiable adjudication closure | No PRF adjudication proof is included; the profile's resolution evidence is not independently verified by PRF. |

The machine-readable boundary is in
`config/sew-full-appeal-capabilities.json`; the Full Appeal artifact gate checks
that disabled capabilities remain out of the allowlist and retains the required
post-deployment assertions. Artifact exclusion alone does not prove that an
external contract or capability is disabled at runtime. A deployment runner
must consume those assertions and fail closed if any differ from the expected
state before activation. This repository's artifact gate does not itself query
deployed state.

## Separate profile boundaries

| Profile | Acceptance boundary |
|---|---|
| Sew Core | Standalone escrow; no internal appeal or BondLedger claim. |
| Sew Full Appeal | Internal resolver appeals and BondLedger custody. |
| Sew External Arbitration | Full Appeal plus separately qualified Kleros integration. |
| Sew DR v3 | Staking, slashing, and collateralized resolver economics. |
| Sew Yield | Yield-backed custody and recovery. |

This profile's current target is Monad Testnet, whose documented runtime limit
is 128 KiB. Qualification checks each runtime against that target-specific
limit; it does not claim EIP-170 compatibility. The older Base Sepolia bundle
and its source-bound review remain a separate, immutable candidate and do not
qualify this revision. A target-specific deployment profile, clean rebuild,
independent security review, and deployment rehearsal are still required.
