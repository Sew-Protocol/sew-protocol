/**
 * Address Validation and Formatting Utilities
 *
 * Production-ready address validation and formatting utilities.
 * Uses EIP-55 checksum validation where appropriate.
 */

import { ethers } from 'ethers';

/**
 * Ethereum address regex pattern (production-ready)
 * Matches: 0x followed by exactly 40 hexadecimal characters (case-insensitive)
 */
export const ETHEREUM_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;

/**
 * Zero address constant (checksummed)
 */
export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

/**
 * Check if a string is a valid Ethereum address format (basic validation)
 * @param address Address string to validate
 * @returns True if address matches format (0x + 40 hex chars)
 */
export function isValidAddressFormat(address: string): boolean {
  if (!address || typeof address !== 'string') {
    return false;
  }
  return ETHEREUM_ADDRESS_REGEX.test(address.trim());
}

/**
 * Validate and normalize an Ethereum address
 * - Validates format
 * - Normalizes to checksummed format (EIP-55)
 * @param address Address string to validate and normalize
 * @param name Variable name for error messages
 * @returns Checksummed address
 * @throws Error if address is invalid
 */
export function validateAndNormalizeAddress(
  address: string,
  name: string = 'address',
): string {
  if (!address || typeof address !== 'string') {
    throw new Error(`Invalid ${name}: address is required and must be a string`);
  }

  const trimmed = address.trim();

  // Basic format validation
  if (!ETHEREUM_ADDRESS_REGEX.test(trimmed)) {
    throw new Error(
      `Invalid ${name} format: "${address}". Expected 0x followed by 40 hexadecimal characters.`,
    );
  }

  // Normalize to checksummed format (EIP-55)
  try {
    return ethers.getAddress(trimmed);
  } catch (error) {
    throw new Error(
      `Invalid ${name}: "${address}" could not be normalized. ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

/**
 * Check if an address is the zero address
 * @param address Address to check
 * @returns True if address is zero address
 */
export function isZeroAddress(address: string): boolean {
  if (!address) return false;
  const normalized = address.trim().toLowerCase();
  return normalized === ZERO_ADDRESS.toLowerCase();
}

/**
 * Validate that an address is not the zero address
 * @param address Address to validate
 * @param name Variable name for error messages
 * @throws Error if address is zero address
 */
export function validateNotZeroAddress(address: string, name: string = 'address'): void {
  if (isZeroAddress(address)) {
    throw new Error(`Invalid ${name}: zero address is not allowed`);
  }
}

/**
 * Validate an address (format + non-zero)
 * @param address Address to validate
 * @param name Variable name for error messages
 * @param allowZero If true, allows zero address (default: false)
 * @returns Normalized checksummed address
 * @throws Error if address is invalid
 */
export function validateAddress(
  address: string,
  name: string = 'address',
  allowZero: boolean = false,
): string {
  const normalized = validateAndNormalizeAddress(address, name);

  if (!allowZero) {
    validateNotZeroAddress(normalized, name);
  }

  return normalized;
}

/**
 * Format address for display (truncated with ellipsis)
 * @param address Address to format
 * @param startChars Number of characters to show at start (default: 6)
 * @param endChars Number of characters to show at end (default: 4)
 * @returns Formatted address string (e.g., "0x1234...5678")
 */
export function formatAddress(
  address: string,
  startChars: number = 6,
  endChars: number = 4,
): string {
  if (!address || address.length < startChars + endChars) {
    return address;
  }
  return `${address.slice(0, startChars)}...${address.slice(-endChars)}`;
}

/**
 * Format address for display (full checksummed)
 * @param address Address to format
 * @returns Checksummed address or original if invalid
 */
export function formatAddressFull(address: string): string {
  try {
    return validateAndNormalizeAddress(address);
  } catch {
    return address;
  }
}

/**
 * Pretty print address with label
 * @param label Label for the address
 * @param address Address to format
 * @param options Formatting options
 * @returns Formatted string
 */
export function prettyPrintAddress(
  label: string,
  address: string,
  options: {
    full?: boolean;
    startChars?: number;
    endChars?: number;
  } = {},
): string {
  const { full = false, startChars = 6, endChars = 4 } = options;

  if (full) {
    return `${label}: ${formatAddressFull(address)}`;
  }
  return `${label}: ${formatAddress(address, startChars, endChars)}`;
}

/**
 * Filter out invalid addresses from an array
 * @param addresses Array of address strings
 * @param allowZero If true, allows zero address (default: false)
 * @returns Array of valid, normalized addresses
 */
export function filterValidAddresses(
  addresses: (string | undefined | null)[],
  allowZero: boolean = false,
): string[] {
  const valid: string[] = [];

  for (const addr of addresses) {
    if (!addr) continue;

    try {
      const normalized = validateAddress(addr, 'address', allowZero);
      valid.push(normalized);
    } catch {
      // Skip invalid addresses
      continue;
    }
  }

  return valid;
}
