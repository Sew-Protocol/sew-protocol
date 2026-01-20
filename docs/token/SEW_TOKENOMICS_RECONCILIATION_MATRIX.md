# SEW Tokenomics — Reconciliation Matrix (Docs ↔ Code ↔ Tests)
**Scope:** SEW token mechanics + protocol incentives/economics that materially affect SEW utility.  
**Explicitly excluded:** allocations, vesting, circulating schedule.  
**Legend:** ✅ Match · ⚠️ Partial/ambiguous · ❌ Contradiction/missing · 🧪 Test coverage noted

---

## Core token claims (SEW)

| Claim | Docs source | Code source | Tests source | Status | Notes / actions |
|---|---|---|---|---|---|
| SEW is fixed supply (no minting post-deploy) | `docs/governance/GOVERNANCE_IMPLEMENTATION_STATUS.md` | `contracts/token/SewToken.sol` | `test/hardhat/MainnetReleaseSequence.test.ts` (asserts `totalSupply`) | ✅ | Contract has constructor `_mint` and no `mint()` function. |
| Intended total supply is **1B** (18 decimals) | `docs/governance/GOVERNANCE_IMPLEMENTATION_STATUS.md` | `deploy/_config.ts` default supply string is 1B * 1e18; `SewToken` mints constructor arg | N/A (tests use smaller supply) | ⚠️ | **Deployment-time param**: exchange must verify deployed `totalSupply()` and constructor args. |
| Intended symbol is `SEW` | `docs/governance/GOVERNANCE_IMPLEMENTATION_STATUS.md` | `deploy/_config.ts` defaults to `SEW` | `test/hardhat/MainnetReleaseSequence.test.ts` uses `SEW` | ✅ | Exchange should still verify deployed on-chain `symbol()` and constructor args. |
| Governance voting uses ERC20Votes + Governor + Timelock | `docs/WHITEPAPER.md` / governance docs | `contracts/token/SewToken.sol`, `contracts/governance/GovGovernor.sol`, `deploy/30_timelock.ts`, `deploy/40_governor.ts` | `test/hardhat/MainnetReleaseSequence.test.ts` (delegation flows) | ✅ | Exchange diligence should confirm current owners/roles and timelock delay. |
| Safe is the initial owner before timelock | governance docs | `deploy/10_safe.ts` | N/A | ⚠️ | `deploy/10_safe.ts` is a **placeholder** in parts; provide actual Safe address & policy in exchange package. |

---

## Protocol fees / revenue claims (not necessarily SEW-denominated)

| Claim | Docs source | Code source | Tests source | Status | Notes / actions |
|---|---|---|---|---|---|
| Escrow fee exists, charged at creation as `fee = amount * escrowFee / 10000` | `docs/FEE_IMPLEMENTATION_SUMMARY.md` | `contracts/core/BaseEscrow.sol` (fee calc at create) | (find/confirm in hardhat/foundry escrow tests) | ✅🧪 | Fee recipient is `escrowFeeAddress` and is timelock-controlled via slow-lane queue/activate. |
| Escrow fees are withdrawable by fee recipient | docs (fee summary + plans) | `contracts/core/EscrowVault.sol::withdrawFees` (token-specific) | N/A | ✅ | `EscrowVault` tracks `totalFeesPerToken`. |
| Yield protocol fee exists and is charged on generated yield only | `docs/FEE_IMPLEMENTATION_SUMMARY.md` | `contracts/core/BaseEscrow.sol` (params + governance), `contracts/YieldOps.sol` (collection) | (add/confirm yield-path tests) | ✅ | Default `yieldProtocolFeeBps` is 3000 (30%). Bounded by `MAX_PROTOCOL_FEE_BPS`. |
| Appeal bond protocol fee exists but is inactive at launch | `docs/FEE_IMPLEMENTATION_SUMMARY.md` | `contracts/core/BaseEscrow.sol` (deducts during escalation bond posting) | (add/confirm bond-fee tests) | ✅ | Default `appealBondProtocolFeeBps` is 0 (0%). When enabled, fee is deducted at bond posting time. |

---

## Dispute-resolution incentives (appeal bonds, resolver payments)

| Claim | Docs source | Code source | Tests source | Status | Notes / actions |
|---|---|---|---|---|---|
| Appeal bonds: refunded if outcome flips; paid to prior round resolvers if outcome upheld | `docs/dispute-resolution/RESOLVER_ECONOMICS.md` | `contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol` | `test/foundry/decentralized-resolution-module/AppealBondDistribution.unit.t.sol` etc. | ✅🧪 | Implementation includes edge case “no resolvers → bond retained”. |
| Appeal bond protocol fee is implemented but defaults to 0% at launch | `docs/token/SEW_TOKENOMICS_EXCHANGE_DRAFT.md` / `docs/FEE_IMPLEMENTATION_SUMMARY.md` | `contracts/core/BaseEscrow.sol` (deducts at bond posting when enabled) | (optional: add a focused test) | ✅ | When `appealBondProtocolFeeBps = 0`, bonds are refunded/distributed in full. |
| Resolver payments weighted by escalation level (1x, 1.5x, 2x) | `docs/test/INCENTIVE_VERIFICATION_PLAN.md` | `contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol` | (find/confirm tests) | ✅🧪 | Payment calculation library is pure and upgradeable by swapping contract address in module. |

---

## SEW as economic collateral (DR v3 staking/slashing)

| Claim | Docs source | Code source | Tests source | Status | Notes / actions |
|---|---|---|---|---|---|
| Resolvers can stake a mix of stable + SEW; enforce 80/20 + haircut | `docs/dispute-resolution/BOND_VALUATION_SUMMARY.md` | `contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol` (+ `BondValuationLibrary`) | `test/foundry/decentralized-resolution-module/*Bond*` invariants | ✅🧪 | Code uses 50% haircut and enforces mix. |
| SEW price is market-priced via input/oracle | `BOND_VALUATION_SUMMARY.md` describes `sewPrice` input | `ResolverStakingModuleV1` uses constant `sewPrice = $1` (oracle-free) | N/A | ⚠️ | Must be disclosed as **oracle-free fixed price assumption** in staking math. |
| Slashing distributes slashed value across protocol/insurance/counterparty | DR docs/status mention distribution | `ResolverSlashingModuleV1` distributes based on stable amounts; insurance vault is stable-token-only | `test/foundry/decentralized-resolution-module/Slashing*` invariants | ⚠️🧪 | Counterparty share is currently 0; treasury routing is not integrated; see next rows. |
| Slashing appeal requires posting an appeal bond (anti-spam) | DR docs mention bonded appeals | `ResolverSlashingModuleV1.appealSlash()` records `appealBond` but does not transfer/escrow funds | N/A | ❌ | Either implement bond custody or remove “bonded” claim. |
| Slashed SEW is burned (deflationary sink) | `docs/dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md` | `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol` | `test/foundry/decentralized-resolution-module/SlashingModuleUnit.t.sol` | ✅🧪 | Slashed SEW is handled as burned (not protocol revenue). |

---

## Immediate recommendations for the exchange/IEO pack
- Provide the **exact deployed contract addresses**, verified source, and constructor args for `SewToken`.
- Provide a **governance surface map** (roles → powers → delays → owners) and the real Safe address/threshold.
- In the tokenomics narrative, label the following as **planned** unless code is changed:
  - counterparty compensation from slashing
  - slashing appeal bond custody

