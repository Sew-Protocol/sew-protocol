## Denomination: safest approach with minimal oracle complexity

### Design goal

Avoid introducing a price oracle dependency just to size bonds---this is a major new attack surface.

### Recommended default (v3)

**Resolver + senior bonds denominated in the same token you already use for "protocol-economic security."**

Given your system may escrow arbitrary ERC20s, the safest operational approach is:

1.  **For v3, restrict "DR-secured escrows" to an allowlist of bond tokens**, set by DAO (slow lane).

2.  **Start with a stablecoin bond token (USDC/DAI)** as the default for resolver/senior bonds.

3.  Allow "escrow token bonds" only for tokens with low volatility (i.e., stablecoins) until you have more maturity.

Why this works:

- Stable denomination makes parameters meaningful and predictable.

- No oracle needed.

- Prevents governance manipulation where someone pumps/dumps a volatile token to game bond requirements.

This is aligned with how optimistic oracle and arbitration systems often parameterize bond/liveness per request and care about the token used for bonding.
