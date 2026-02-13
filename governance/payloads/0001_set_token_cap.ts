/**
 * Payload: Set Token Cap (Standard Lane)
 *
 * Sets a cap for a specific token in AaveYieldModule.
 * This is a Standard lane action (48-hour Timelock delay).
 */

import { PayloadBuilder } from '../../scripts/gov/types';
import { getDeployedAddress } from '../../scripts/gov/addresses';
import { validateAddress } from '../../scripts/_lib/addresses';

/**
 * Safely parse an integer from a string
 * @param value String value to parse
 * @param name Variable name for error messages
 * @param defaultValue Default value if value is not provided
 * @returns Parsed integer
 * @throws Error if value cannot be parsed as an integer
 */
function parseInteger(value: string | undefined, name: string, defaultValue: number): number {
  const str = value || defaultValue.toString();
  const trimmed = str.trim();

  // Check if the entire string is numeric (allows negative numbers)
  if (!/^-?\d+$/.test(trimmed)) {
    throw new Error(
      `Invalid ${name}: "${str}" is not a valid integer. Expected a whole number.`,
    );
  }

  const parsed = parseInt(trimmed, 10);

  // Double-check parsing succeeded
  if (isNaN(parsed) || !Number.isInteger(parsed)) {
    throw new Error(`Invalid ${name}: "${str}" could not be parsed as an integer.`);
  }

  return parsed;
}

export const metadata = {
  id: '0001_set_token_cap',
  title: 'Set Token Cap for USDC',
  description: `
Set a cap of 10M USDC for Aave yield generation.

This proposal sets a maximum exposure limit for USDC deposits in the Aave yield generation module.
This helps manage risk by limiting the total amount of USDC that can be deposited into Aave.

**Parameters:**
- Token: USDC (0x...)
- Cap: 10,000,000 USDC (6 decimals)
  `,
  lane: 'standard' as const,
  requiredContracts: ['AaveYieldModule'],
  config: {
    // Override these via command line or environment
    tokenAddress: process.env.TOKEN_ADDRESS || '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // Base USDC
    capAmount: process.env.CAP_AMOUNT || '10000000', // 10M USDC
    tokenDecimals: process.env.TOKEN_DECIMALS || '6', // USDC has 6 decimals
  },
};

const buildPayload: PayloadBuilder = async (hre, config) => {
  // Allow placeholder for offline proposal building
  const aaveModule = await getDeployedAddress(hre, 'AaveYieldModule', true);

  // Use config from metadata or override
  const tokenAddressRaw = config?.tokenAddress || metadata.config.tokenAddress;
  const tokenAddress = validateAddress(tokenAddressRaw, 'TOKEN_ADDRESS', false);
  const capAmount = config?.capAmount || metadata.config.capAmount;
  const tokenDecimals = parseInteger(
    config?.tokenDecimals || metadata.config.tokenDecimals,
    'TOKEN_DECIMALS',
    6, // Default: 6 decimals (USDC)
  );

  // Parse cap amount with correct decimals
  const capWei = hre.ethers.parseUnits(capAmount, tokenDecimals);

  return [
    {
      target: aaveModule,
      contractName: 'AaveYieldModule',
      functionName: 'setTokenCap',
      args: [tokenAddress, capWei],
      description: `Set USDC cap to ${capAmount} (${capWei.toString()} wei)`,
    },
  ];
};

export default buildPayload;
