# Number Parsing Audit

**Date:** 2026-01-16  
**Status:** ✅ Complete

## Summary

Audited all files for unsafe number parsing (`parseInt()`, `Number()`, `BigInt()`) and ensured consistent use of safe parsing helpers throughout the codebase.

## Files Audited

### ✅ Fixed Files

1. **`deploy/_config.ts`**
   - ✅ Added `parseInteger()` helper function
   - ✅ Replaced all `parseInt()` and `Number()` calls with `parseInteger()`
   - ✅ Enhanced `validateGovConfig()` with NaN and integer validation
   - ✅ Fixed `BigInt()` validation to use proper error handling

2. **`config/governance.config.ts`**
   - ✅ Added `parseInteger()` and `parseBigInt()` helper functions
   - ✅ Replaced all `parseInt()` calls with `parseInteger()`
   - ✅ Enhanced `validateConfig()` with comprehensive validation
   - ✅ Added `proposalThreshold` validation using `parseBigInt()`

3. **`governance/payloads/0001_set_token_cap.ts`**
   - ✅ Added `parseInteger()` helper function
   - ✅ Replaced `parseInt()` call with `parseInteger()`
   - ✅ Added proper validation and error handling

### ✅ Verified Acceptable Usage

4. **`deploy/40_governor.ts`**
   - ✅ Uses `BigInt()` for formatting already-validated config values
   - ✅ Acceptable: Values come from validated `config` object
   - Lines 36, 69: Formatting `config.governor.proposalThreshold` (already validated)

5. **`deploy/20_gov_token.ts`**
   - ✅ Uses `BigInt()` for formatting already-validated config values
   - ✅ Acceptable: Values come from validated `config` object
   - Lines 22, 50, 64: Formatting `config.token.initialSupply` and `mint.amount` (already validated)

## Safe Parsing Helpers

### `parseInteger()`
Located in:
- `deploy/_config.ts`
- `config/governance.config.ts`
- `governance/payloads/0001_set_token_cap.ts`

Features:
- Trims whitespace
- Validates entire string is numeric (regex `/^-?\d+$/`)
- Uses `parseInt(value, 10)` with radix
- Validates result is not `NaN` and is an integer
- Provides clear error messages

### `parseBigInt()`
Located in:
- `config/governance.config.ts`

Features:
- Trims whitespace
- Validates entire string is numeric (regex `/^-?\d+$/`)
- Validates value is greater than 0
- Provides clear error messages
- Handles parsing errors gracefully

## Linting Rules Added

Added ESLint rule in `.eslintrc.cjs` to catch unsafe parsing:

```javascript
'no-restricted-syntax': [
  'error',
  {
    selector: 'CallExpression[callee.name="parseInt"][arguments.length<2]',
    message: 'Use parseInteger() helper instead of parseInt() without validation...',
  },
  // ... additional rules for Number() and BigInt()
]
```

## Documentation Created

1. **`docs/CODING_STANDARDS.md`**
   - Comprehensive guide on number parsing standards
   - Examples of safe vs unsafe parsing
   - When direct parsing is acceptable
   - Checklist for developers

2. **`docs/NUMBER_PARSING_AUDIT.md`** (this file)
   - Audit results and findings

## Best Practices Established

1. **Always use safe parsing helpers** for:
   - Environment variables
   - User input
   - Configuration values
   - Any untrusted string input

2. **Direct parsing is acceptable** for:
   - Already-validated values (from validated config objects)
   - Formatting/display purposes only
   - Trusted sources (contract return values)

3. **Validation requirements:**
   - Check for `NaN`
   - Verify integer values with `Number.isInteger()`
   - Validate BigInt values are > 0 (if required)
   - Provide meaningful error messages

## Future Prevention

1. ✅ ESLint rule added to catch unsafe parsing
2. ✅ Documentation created (`docs/CODING_STANDARDS.md`)
3. ✅ Helper functions available in multiple files
4. ✅ Examples provided in documentation

## Checklist for New Code

When adding new number parsing:
- [ ] Use `parseInteger()` or `parseBigInt()` helpers
- [ ] Provide meaningful variable names in error messages
- [ ] Validate parsed values are not `NaN`
- [ ] Check integer values with `Number.isInteger()`
- [ ] Add validation in `validateConfig()` functions
- [ ] Run ESLint to catch any unsafe parsing

## Related Files

- `deploy/_config.ts` - Main deployment config with `parseInteger()` helper
- `config/governance.config.ts` - Governance config with both helpers
- `governance/payloads/0001_set_token_cap.ts` - Example payload with safe parsing
- `.eslintrc.cjs` - ESLint rules to prevent unsafe parsing
- `docs/CODING_STANDARDS.md` - Complete coding standards guide
