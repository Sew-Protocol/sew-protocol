# Currency Management Summary

## Quick Reference

| Currency Type | Current Default | Production Default | Governance Control |
|--------------|----------------|-------------------|-------------------|
| **Escrow Amount** | User choice | User choice | None |
| **Escrow Fee** | Same as escrow | Same as escrow | N/A (enforced) |
| **Appeal Bond** | ETH (`address(0)`) | **USD Stablecoin** | Slow lane (7 days) |
| **Resolver Incentives** | Same as escrow fee | Same as escrow fee | N/A (enforced) |

## Key Restrictions

1. **Escrow fees are always paid in the same token as the escrow amount**
2. **Resolver incentives are always paid in the same token as escrow fees**
3. **Appeal bonds currently accept a single token (governance-controlled)**
   - **TODO**: Add whitelist of accepted tokens

## Documentation

- **`CURRENCY_MANAGEMENT.md`**: Comprehensive analysis of all currency choices
- **`APPEAL_BOND_TOKEN_WHITELIST_PLAN.md`**: Implementation plan for multi-token support

## Next Steps

1. ✅ Document currency choices and restrictions
2. ⏳ Update default bond token to USD stablecoin (deployment-time configuration)
3. ⏳ Implement token whitelist for appeal bonds
4. ⏳ Add validation for bond tokens
