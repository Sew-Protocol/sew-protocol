# Address Validation Standards

**Date:** 2026-01-16  
**Status:** ✅ Complete

## Summary

Standardized Ethereum address validation and formatting across the codebase using a production-ready utility library with EIP-55 checksum validation.

## Address Validation Utility

**Location:** `scripts/_lib/addresses.ts`

### Features

1. **Format Validation**
   - Regex pattern: `/^0x[a-fA-F0-9]{40}$/`
   - Validates 0x prefix + exactly 40 hexadecimal characters
   - Case-insensitive matching

2. **Checksum Validation (EIP-55)**
   - Uses `ethers.getAddress()` for checksum normalization
   - Ensures addresses are in proper checksummed format
   - Prevents case-sensitivity issues

3. **Zero Address Handling**
   - Constant: `ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'`
   - Helper: `isZeroAddress(address)` - checks if address is zero
   - Helper: `validateNotZeroAddress(address, name)` - throws if zero

4. **Pretty Printing**
   - `formatAddress(address, startChars, endChars)` - truncated display (e.g., "0x1234...5678")
   - `formatAddressFull(address)` - full checksummed address
   - `prettyPrintAddress(label, address, options)` - labeled display

5. **Array Utilities**
   - `filterValidAddresses(addresses, allowZero)` - filters and normalizes array

### API Reference

```typescript
// Basic validation
isValidAddressFormat(address: string): boolean

// Validate and normalize (with checksum)
validateAndNormalizeAddress(address: string, name?: string): string

// Check zero address
isZeroAddress(address: string): boolean
validateNotZeroAddress(address: string, name?: string): void

// Full validation (format + non-zero)
validateAddress(address: string, name?: string, allowZero?: boolean): string

// Formatting
formatAddress(address: string, startChars?: number, endChars?: number): string
formatAddressFull(address: string): string
prettyPrintAddress(label: string, address: string, options?: {...}): string

// Array utilities
filterValidAddresses(addresses: Array<string | undefined | null>, allowZero?: boolean): string[]
```

## Files Updated

### Core Configuration Files

1. **`deploy/_config.ts`**
   - ✅ Replaced inline regex with `validateAddress()` and `validateAndNormalizeAddress()`
   - ✅ Replaced zero address string checks with `isZeroAddress()`
   - ✅ Normalizes all addresses to checksummed format
   - ✅ Enhanced error messages with variable names

2. **`config/governance.config.ts`**
   - ✅ Replaced zero address string checks with `isZeroAddress()`
   - ✅ Normalizes Safe owner addresses to checksummed format
   - ✅ Uses `validateAndNormalizeAddress()` for all owner addresses

### Governance Payloads

3. **`governance/payloads/0001_set_token_cap.ts`**
   - ✅ Added `validateAddress()` for token address validation
   - ✅ Normalizes token address to checksummed format

4. **`governance/payloads/0002_queue_fee_address.ts`**
   - ✅ Replaced zero address string checks with `isZeroAddress()`
   - ✅ Added `validateAddress()` for fee address validation
   - ✅ Normalizes fee address to checksummed format

5. **`governance/payloads/0005_queue_resolution_module.ts`**
   - ✅ Replaced zero address string checks with `isZeroAddress()`
   - ✅ Added `validateAddress()` for module address validation
   - ✅ Normalizes module address to checksummed format

### Scripts

6. **`scripts/gov/simulate-hardhat.ts`**
   - ✅ Replaced zero address string checks with `isZeroAddress()`
   - ✅ Added `prettyPrintAddress()` for executor address display
   - ✅ Uses full address formatting for better readability

## Best Practices

### ✅ DO

1. **Always use the utility functions** for address validation
   ```typescript
   // ✅ GOOD
   const address = validateAddress(envVar, 'TOKEN_ADDRESS', false);
   ```

2. **Normalize addresses** to checksummed format
   ```typescript
   // ✅ GOOD
   const normalized = validateAndNormalizeAddress(address, 'ADDRESS');
   ```

3. **Use `isZeroAddress()`** instead of string comparison
   ```typescript
   // ✅ GOOD
   if (isZeroAddress(address)) { ... }
   ```

4. **Use pretty printing** for user-facing output
   ```typescript
   // ✅ GOOD
   console.log(prettyPrintAddress('Token', address, { full: true }));
   ```

5. **Provide meaningful variable names** in error messages
   ```typescript
   // ✅ GOOD
   validateAddress(addr, 'SAFE_OWNER_1', false);
   ```

### ❌ DON'T

1. **Don't use inline regex** for address validation
   ```typescript
   // ❌ BAD
   if (!/^0x[a-fA-F0-9]{40}$/.test(address)) { ... }
   ```

2. **Don't compare zero address as string**
   ```typescript
   // ❌ BAD
   if (address === '0x0000000000000000000000000000000000000000') { ... }
   ```

3. **Don't skip checksum validation** for production addresses
   ```typescript
   // ❌ BAD
   const address = process.env.ADDRESS; // No validation
   ```

4. **Don't use lowercase addresses** in production
   ```typescript
   // ❌ BAD
   const address = '0x1234...5678'.toLowerCase();
   ```

## Regex Pattern

**Production-ready regex:** `/^0x[a-fA-F0-9]{40}$/`

- `^0x` - Must start with "0x"
- `[a-fA-F0-9]{40}` - Exactly 40 hexadecimal characters (case-insensitive)
- `$` - End of string (prevents partial matches)

**Why this pattern:**
- ✅ Validates format before checksum validation
- ✅ Case-insensitive (checksum handled separately)
- ✅ Anchored (prevents partial matches)
- ✅ Simple and performant

## Checksum Validation

All addresses are normalized using `ethers.getAddress()` which:
- ✅ Validates EIP-55 checksum format
- ✅ Normalizes to proper checksummed case
- ✅ Throws clear errors for invalid addresses
- ✅ Handles both checksummed and non-checksummed input

## Zero Address Handling

**Constant:** `ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'`

**Usage:**
```typescript
// Check if zero
if (isZeroAddress(address)) { ... }

// Validate not zero
validateNotZeroAddress(address, 'ADDRESS');

// Allow zero (if needed)
validateAddress(address, 'ADDRESS', true); // allowZero = true
```

## Pretty Printing

### Truncated Display
```typescript
formatAddress('0x1234567890abcdef1234567890abcdef12345678', 6, 4)
// Returns: "0x1234...5678"
```

### Full Display
```typescript
formatAddressFull('0x1234567890abcdef1234567890abcdef12345678')
// Returns: "0x1234567890AbCdEf1234567890AbCdEf12345678" (checksummed)
```

### Labeled Display
```typescript
prettyPrintAddress('Token', address, { full: true })
// Returns: "Token: 0x1234567890AbCdEf1234567890AbCdEf12345678"
```

## Migration Notes

### Before
```typescript
const addressRegex = /^0x[a-fA-F0-9]{40}$/;
if (!addressRegex.test(address)) {
  throw new Error(`Invalid address: ${address}`);
}
if (address === '0x0000000000000000000000000000000000000000') {
  throw new Error('Zero address not allowed');
}
```

### After
```typescript
import { validateAddress } from '../scripts/_lib/addresses';

const normalized = validateAddress(address, 'ADDRESS', false);
// Automatically validates format, checksum, and non-zero
```

## Testing

All address validation functions:
- ✅ Validate format (regex)
- ✅ Validate checksum (EIP-55)
- ✅ Handle zero address correctly
- ✅ Provide clear error messages
- ✅ Normalize to checksummed format

## Related Files

- `scripts/_lib/addresses.ts` - Address validation utility
- `deploy/_config.ts` - Deployment configuration (uses address validation)
- `config/governance.config.ts` - Governance configuration (uses address validation)
- `governance/payloads/*.ts` - Governance payloads (use address validation)
- `scripts/gov/simulate-hardhat.ts` - Simulation script (uses address formatting)

## Future Enhancements

Potential improvements:
- [ ] Add address validation for contract addresses (check code.length > 0)
- [ ] Add address validation for EOA vs contract detection
- [ ] Add address validation for specific network addresses
- [ ] Add batch address validation utilities
- [ ] Add address comparison utilities (case-insensitive, checksum-aware)
