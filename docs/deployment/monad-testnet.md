# Monad Testnet deployment alternative

Monad Testnet is registered as a candidate alternative for Sew core deployment.
It uses chain ID `10143`, RPC `https://testnet-rpc.monad.xyz/`,
native currency `MON`, and explorer `https://testnet.monadexplorer.com/`.
Monad documents a 128 KB maximum contract-code size, so this is a candidate
destination for the oversized Sew escrow runtime. Confirm the active testnet
behavior with a current deployment simulation before sending transactions.
Monad charges transaction fees based on the transaction gas limit rather than
gas used, so budget the complete sequence of deployment and wiring transactions
against the reported 5 MON balance.

The configured deployer is
`0xE8d7Fbd5Db3ad910370Be315f21D4596ed45122f`. The runtime checks that the
configured signer matches this address before deployment. The reported balance
is 5 MON; confirm current balance and estimate the selected deployment's gas
before broadcasting, since this configuration does not guarantee that balance
is sufficient.

## Deployment route

Store the key in `envsec` context `testnet-deploy-keys` under
`TESTNET_MONAD_DEPLOY_KEY`. Inject it into the process environment when running
Hardhat; do not copy the secret into `.env`, logs, or deployment records.

Do not deploy directly with `hardhat deploy --network monadTestnet` yet. The
existing scripts are the historical full Sew deployment, not the selected
standalone-core profile: the `core` tag omits required escrow-admin and selected
release/resolution deployment steps, while the unfiltered script includes
network-specific integrations and can send earlier transactions before the
unsupported Aave step fails. The Aave deployment script fails closed when no
pool is configured, but that guard does not make the full script sequence safe
for Monad.

Recommended route: build and export the pinned Sew artifacts from this
repository, then deploy them with `protocol-deployments` after adding a
Monad-specific Sew profile, a selected Monad test asset, fresh-chain rehearsal,
and independent review. The current generic Sew profile is Base Sepolia-bound;
this network registration alone does not make that profile executable.

The Sew test asset and any external protocol dependencies still need to be
selected for Monad. The existing Base Sepolia USDC address must not be reused
on Monad. Aave V3 yield testing also remains unavailable on this target until
an Aave deployment and supported reserve asset are verified. This network entry
does not itself qualify the contracts for deployment or authorize a live run.
