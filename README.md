# hardhat-deploy-hybrid (classic hardhat-deploy + Foundry)

This scaffold uses **classic** `hardhat-deploy` (not Ignition) and supports:
- **Complex multi-step deployments** (script ordering + tags)
- **Upgradeable deployments**: **Transparent** or **UUPS** (select via `PROXY_KIND`)
- **Hardhat tests** (TypeScript)
- **Foundry tests** (forge)
- A timestamped deployment ledger in `deploy-ledger/<network>/<stamp>/`

## Quick start
```bash
pnpm i
cp .env.example .env
pnpm test
```

## Deploy locally
```bash
pnpm deploy:local
pnpm export --network hardhat
```

## Deploy with proxies
Transparent (default):
```bash
pnpm deploy --network baseSepolia
```

UUPS:
```bash
PROXY_KIND=uups pnpm deploy --network baseSepolia
```

## Deploy flow (example)
- `deploy/00_impl.ts` deploys impl for bookkeeping
- `deploy/10_proxy.ts` deploys proxy + runs initializer
- `deploy/90_post.ts` sanity checks / wiring

## Production safety notes
- Gate upgrades behind **Safe + Timelock**.
- Require **storage layout checks** on every upgrade.
- Never leave upgrade authority on an EOA.
