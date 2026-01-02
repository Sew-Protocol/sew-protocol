/**
 * Payload: Activate Escrow Fee Address (Slow Lane)
 * 
 * Activates a previously queued escrow fee address change.
 * This can only be called after the 7-day delay has elapsed.
 * 
 * Prerequisites:
 * - A fee address must have been queued via queueEscrowFeeAddress()
 * - 7 days must have passed since the queue transaction
 */

import { PayloadBuilder } from "../../scripts/gov/types";
import { getDeployedAddress } from "../../scripts/gov/addresses";

export const metadata = {
  id: "0003_activate_fee_address",
  title: "Activate Queued Escrow Fee Address",
  description: `
Activate a previously queued escrow fee address change.

This proposal activates a fee address change that was queued at least 7 days ago.
The change will take effect immediately upon execution.

**Prerequisites:**
- Fee address must have been queued via proposal 0002_queue_fee_address
- 7 days must have elapsed since the queue transaction
  `,
  lane: "slow" as const,
  requiredContracts: ["EscrowableERC20", "EscrowVault"],
  config: {
    targetContract: process.env.TARGET_CONTRACT || "EscrowableERC20", // "EscrowableERC20" or "EscrowVault"
  },
};

const buildPayload: PayloadBuilder = async (hre, config) => {
  const targetContractName = config?.targetContract || metadata.config.targetContract;
  const contractAddress = await getDeployedAddress(hre, targetContractName, true);
  
  return [
    {
      target: contractAddress,
      contractName: targetContractName,
      functionName: "activateEscrowFeeAddress",
      args: [],
      description: `Activate queued fee address for ${targetContractName}`,
    },
  ];
};

export default buildPayload;

