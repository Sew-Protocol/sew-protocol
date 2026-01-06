Approach

Treat “Standard” as your parameter-change lane and set a default delay that matches Ethereum norms without killing iteration speed.

Provide a concrete Standard-lane configuration (delay + bounds philosophy + which functions belong there).

Give a drop-in “policy text” you can paste into docs.

Standard lane (recommended default)

Standard lane timelock delay: 48 hours.

Why 48h fits Jan-2026 Ethereum expectations:

Long enough for delegates/whitehats to review and react.

Short enough that you can still iterate on parameters without stalling operations.

Commonly accepted as a baseline delay for non-critical parameter tuning in DeFi governance (with “Slow” lanes longer for module swaps / fee recipient changes).

Standard lane definition (what goes here)

Standard = bounded parameter changes + operational config that cannot redirect user funds or rewrite escrow terms.

From your surface map, Standard includes:

setDefaultAutoCancelTime

setDefaultAutoReleaseTime

setMaxAttachments

setResolutionModuleDelay (with bounds)

setDefaultYieldDistribution

setEscrowYieldDistribution (only if it cannot affect in-flight escrows)

Aave ops: setAaveEnabled (enable via timelock), registerTokenForAave, batchRegisterTokensForAave

Resolver updates inside modules: DefaultResolutionModule.setResolver

DecentralizedResolutionModule.setExternalResolver

Standard lane guardrails (non-negotiables for credibility)

Hard bounds onchain (in SettingsValidationLibrary) for every Standard parameter.

No per-escrow discretionary overrides in Standard (15–18 should be deprecated or limited to deterministic routing).

No retroactive changes: Standard changes apply to new escrows unless explicitly governed via Slow lane and clearly disclosed.

Policy text you can paste into docs (Standard lane)

Standard Governance Lane (48h Timelock).
Standard lane actions are changes to bounded operational parameters and configurations that do not alter the rules of in-flight escrows, cannot redirect user funds, and cannot expand protocol authority beyond pre-defined limits. All Standard lane actions are executed exclusively by the Timelock after a 48-hour delay. Parameter bounds are enforced onchain.

Assumptions

You want a single global Standard delay (not per-parameter).

You’ll use a longer Slow delay for module swaps, fee recipient changes, and governance infrastructure.

You’re aiming for Ethereum-native credibility (delegates expect time to review queued actions).

Next steps

Tell me your Slow lane delay preference (common: 7 days) and I’ll finalize the full lane policy.

I can output the exact Timelock role wiring (who has PROPOSER/EXECUTOR/CANCELLER) aligned to your lanes.

I can propose concrete bounds for each Standard parameter based on your product requirements.

What I need from you

Do you want Standard = 48h locked in, or do you prefer 24h / 72h?

What’s your target for Slow lane delay (e.g., 7 days)?


