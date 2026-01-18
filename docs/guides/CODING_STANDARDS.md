# Coding Standards

This document outlines coding standards and best practices for the project.

## Number Parsing Standards

### Problem

Direct use of `parseInt()`, `Number()`, or `BigInt()` without validation can lead to:
- Silent failures (returning `NaN`)
- Partial parsing (`parseInt("123abc")` returns `123`)
- Type safety issues
- Runtime errors from invalid input

### Solution

**Always use safe parsing helpers** when parsing numbers from environment variables or user input.

### Safe Parsing Functions

#### For Integers

Use the `parseInteger()` helper function:

```typescript
/**
 * Safely parse an integer from an environment variable
 * @param envVar Environment variable value
 * @param defaultValue Default value if env var is not set
 * @param name Variable name for error messages
 * @returns Parsed integer
 * @throws Error if value cannot be parsed as an integer
 */
function parseInteger(
  envVar: string | undefined,
  defaultValue: number,
  name: string,
): number {
  const value = envVar || defaultValue.toString();
  const trimmed = value.trim();
  
  // Check if the entire string is numeric (allows negative numbers)
  if (!/^-?\d+$/.test(trimmed)) {
    throw new Error(
      `Invalid ${name}: "${value}" is not a valid integer. Expected a whole number.`,
    );
  }
  
  const parsed = parseInt(trimmed, 10);

  // Double-check parsing succeeded
  if (isNaN(parsed) || !Number.isInteger(parsed)) {
    throw new Error(
      `Invalid ${name}: "${value}" could not be parsed as an integer.`,
    );
  }

  return parsed;
}
```

**Usage:**
```typescript
// ❌ BAD
const threshold = parseInt(process.env.SAFE_THRESHOLD || '3');

// ✅ GOOD
const threshold = parseInteger(process.env.SAFE_THRESHOLD, 3, 'SAFE_THRESHOLD');
```

#### For BigInt

Use the `parseBigInt()` helper function:

```typescript
/**
 * Safely parse a BigInt from a string
 * @param value String value to parse
 * @param name Variable name for error messages
 * @returns Parsed BigInt
 * @throws Error if value cannot be parsed as a BigInt
 */
function parseBigInt(value: string, name: string): bigint {
  const trimmed = value.trim();

  // Check if the entire string is numeric (allows negative numbers)
  if (!/^-?\d+$/.test(trimmed)) {
    throw new Error(
      `Invalid ${name}: "${value}" is not a valid integer string for BigInt parsing.`,
    );
  }

  try {
    const parsed = BigInt(trimmed);
    if (parsed === 0n) {
      throw new Error(`Invalid ${name}: value must be greater than 0`);
    }
    return parsed;
  } catch (error) {
    if (error instanceof Error && error.message.includes('must be greater than 0')) {
      throw error;
    }
    throw new Error(
      `Invalid ${name}: "${value}" could not be parsed as a BigInt. ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}
```

**Usage:**
```typescript
// ❌ BAD
if (BigInt(config.token.initialSupply) === 0n) {
  throw new Error('Invalid supply');
}

// ✅ GOOD
try {
  parseBigInt(config.token.initialSupply, 'GOVERNANCE_TOKEN_SUPPLY');
} catch (error) {
  errors.push(error.message);
}
```

### When Direct Parsing is Acceptable

Direct parsing is acceptable **only** when:
1. The value has already been validated (e.g., from a validated config object)
2. The value is used for formatting/display purposes only
3. The value comes from a trusted source (e.g., contract return values)

**Example (acceptable):**
```typescript
// Value already validated via parseInteger() earlier
const thresholdFormatted = (BigInt(config.governor.proposalThreshold) / BigInt(10 ** 18)).toString();
```

### Files with Safe Parsing Helpers

- `deploy/_config.ts` - Contains `parseInteger()` helper
- `config/governance.config.ts` - Contains `parseInteger()` and `parseBigInt()` helpers
- `governance/payloads/0001_set_token_cap.ts` - Contains `parseInteger()` helper

### Linting Rule

Add this to your ESLint config or use a custom rule to catch unsafe parsing:

```javascript
// .eslintrc.cjs
rules: {
  'no-restricted-syntax': [
    'error',
    {
      selector: 'CallExpression[callee.name="parseInt"][arguments.length<2]',
      message: 'Use parseInteger() helper instead of parseInt() without radix. Always specify radix 10 and validate input.',
    },
    {
      selector: 'CallExpression[callee.name="Number"][arguments[0].type!="Literal"]',
      message: 'Use parseInteger() or parseBigInt() helper instead of Number() for parsing. Validate input first.',
    },
    {
      selector: 'CallExpression[callee.name="BigInt"][arguments[0].type!="Literal"]',
      message: 'Use parseBigInt() helper instead of BigInt() for parsing. Validate input first.',
    },
  ],
}
```

### Checklist

When parsing numbers, ensure:
- [ ] Using `parseInteger()` or `parseBigInt()` helper functions
- [ ] Providing meaningful variable names in error messages
- [ ] Validating parsed values are not `NaN`
- [ ] Checking integer values with `Number.isInteger()`
- [ ] Validating BigInt values are greater than 0 (if required)
- [ ] Adding validation in `validateConfig()` functions

### Examples

See these files for reference implementations:
- `deploy/_config.ts` - `getGovConfig()` function
- `config/governance.config.ts` - `GOVERNANCE_CONFIG` and `validateConfig()`
- `governance/payloads/0001_set_token_cap.ts` - `buildPayload()` function
