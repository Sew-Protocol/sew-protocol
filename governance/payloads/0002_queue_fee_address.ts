/**
 * Payload: Queue Escrow Fee Address (Slow Lane)
 *
 * Queues a new escrow fee recipient address.
 * This is a Slow lane action (7-day delay + 48-hour Timelock delay).
 *
 * Note: After this proposal executes, you must wait 7 days, then call activateEscrowFeeAddress().
 */

import { PayloadBuilder } from '../../scripts/gov/types';
import { getDeployedAddress } from '../../scripts/gov/addresses';
import { validateAddress, isZeroAddress, ZERO_ADDRESS } from '../../scripts/_lib/addresses';

export const metadata = {
  id: '0002_queue_fee_address',
  title: 'Queue New Escrow Fee Address',
  description: `
Queue a new address to receive escrow fees.

This proposal queues a change to the escrow fee recipient address. After execution:
1. The change is queued with a 7-day delay
2. After 7 days, call activateEscrowFeeAddress() to apply the change

**Parameters:**
- New Fee Address: 0x...
  `,
  lane: 'slow' as const,
  requiredContracts: ['EscrowableERC20', 'EscrowVault'],
  config: {
    // Override via command line or environment
    newFeeAddress: process.env.NEW_FEE_ADDRESS || '0x0000000000000000000000000000000000000000',
    targetContract: process.env.TARGET_CONTRACT || 'EscrowableERC20', // "EscrowableERC20" or "EscrowVault"
  },
};

const buildPayload: PayloadBuilder = async (hre, config) => {
  const targetContractName = config?.targetContract || metadata.config.targetContract;
  const contractAddress = await getDeployedAddress(hre, targetContractName, true);

  const newFeeAddressRaw = config?.newFeeAddress || metadata.config.newFeeAddress;

  // Allow placeholder for offline proposal building
  if (
    isZeroAddress(newFeeAddressRaw) &&
    !newFeeAddressRaw.startsWith('0xPLACEHOLDER_')
  ) {
    // Use placeholder if not set
    const placeholderAddress = '0xPLACEHOLDER_NEW_FEE_ADDRESS';
    console.warn(
      `   ⚠️  Using placeholder address: ${placeholderAddress} (set NEW_FEE_ADDRESS env var for actual address)`,
    );
    return [
      {
        target: contractAddress,
        contractName: targetContractName,
        functionName: 'queueEscrowFeeAddress',
        args: [placeholderAddress],
        description: `Queue new fee address: ${placeholderAddress} (REPLACE WITH ACTUAL ADDRESS)`,
      },
    ];
  }

  // Validate and normalize address
  const newFeeAddress = validateAddress(newFeeAddressRaw, 'NEW_FEE_ADDRESS', false);

  return [
    {
      target: contractAddress,
      contractName: targetContractName,
      functionName: 'queueEscrowFeeAddress',
      args: [newFeeAddress],
      description: `Queue new fee address: ${newFeeAddress}`,
    },
  ];
};

export default buildPayload;
