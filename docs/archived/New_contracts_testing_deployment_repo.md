This repo has been created to modernise the testing and deployment stack, support uups and transparent proxy upgradeable contracts, and manage deployments.

It uses a deployment ledger to keep track of what's been deployed

It uses hardhard classic deployment in favour of hardhat ignition






Approach

Generate a classic hardhat-deploy scaffold (no Ignition) with script ordering + tags for complex deployments.

Make it hybrid: Hardhat tests (TS) + Foundry tests (forge) sharing the same contracts/ sources.

Add robust deployment management supporting Transparent or UUPS proxy via PROXY_KIND, plus a timestamped deployment ledger.

Project generated (hardhat-deploy classic + Hardhat tests + Foundry tests + proxy support)

Download: hardhat-deploy-hybrid.zip

What you get

Classic deployments: deploy/00_impl.ts → deploy/10_proxy.ts → deploy/90_post.ts (tags + dependencies)

Upgradeable deployments: choose proxy type at deploy time

Transparent (default): PROXY_KIND=transparent

UUPS: PROXY_KIND=uups

Both test stacks:

Hardhat TS tests in test/hardhat/

Foundry tests in test/foundry/

Shared Solidity sources: contracts/ used by both Hardhat and Foundry

Deployment ledger bundles: scripts/export-ledger.ts writes to deploy-ledger/<network>/<stamp>/ (meta + addresses + ABI snapshot + hardhat-deploy JSON snapshot)

Quick start
pnpm i
cp .env.example .env
pnpm test

Local deploy + ledger export
pnpm deploy:local
pnpm export --network hardhat

Deploy with proxies
# transparent (default)
pnpm deploy --network baseSepolia

# uups
PROXY_KIND=uups pnpm deploy --network baseSepolia

Notes on “robust” upgrade management

Transparent: admin separation via ProxyAdmin (good operational safety)

UUPS: upgrade logic in implementation; _authorizeUpgrade is enforced (onlyOwner in example)

Hardhat test includes an upgrade demo using OZ upgrades plugin (helper). Foundry tests demonstrate both proxy flows directly.

Assumptions

You want the deployment orchestrator to be hardhat-deploy (classic deployments.deploy() scripts).

You want both Hardhat and Foundry test runners in the same repo.

You’re fine using OpenZeppelin upgradeable patterns and want transparent/UUPS selectable per environment.

Next steps

Replace UpgradeableBox with your real modules and expand deploy scripts to:

deploy shared libraries first

deploy modules in phases (tags)

wire cross-references in a final “linking” stage

Add “governed upgrades” next: Safe + Timelock ownership transfer in a deploy/95_transfer_admin.ts.

If you have many instances (factory pattern), consider adding Beacon proxy support as a third PROXY_KIND.