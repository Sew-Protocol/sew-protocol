/**
 * Payload: Queue Resolution Module (Slow Lane)
 * 
 * Queues a new resolution module for dispute resolution.
 * This is a Slow lane action (7-day delay + 48-hour Timelock delay).
 * 
 * Note: After this proposal executes, you must wait 7 days + resolutionModuleDelay,
 * then call activateResolutionModule().
 */

import { PayloadBuilder } from "../../scripts/gov/types";
import { getDeployedAddress } from "../../scripts/gov/addresses";

export const metadata = {
  id: "0005_queue_resolution_module",
  title: "Queue New Resolution Module",
  description: `
Queue a new resolution module for dispute resolution.

This proposal queues a change to the default resolution module. After execution:
1. The change is queued with a delay (resolutionModuleDelay, typically 48 hours)
2. After the delay, call activateResolutionModule() to apply the change

**Parameters:**
- New Resolution Module Address: 0x...
  `,
  lane: "slow" as const,
  requiredContracts: ["EscrowableERC20", "EscrowVault"],
  config: {
    newResolutionModule: process.env.NEW_RESOLUTION_MODULE || "0x0000000000000000000000000000000000000000",
    targetContract: process.env.TARGET_CONTRACT || "EscrowableERC20", // "EscrowableERC20" or "EscrowVault"
  },
};

const buildPayload: PayloadBuilder = async (hre, config) => {
  const targetContractName = config?.targetContract || metadata.config.targetContract;
  const contractAddress = await getDeployedAddress(hre, targetContractName, true);
  
  const newResolutionModule = config?.newResolutionModule || metadata.config.newResolutionModule;
  
  if (newResolutionModule === "0x0000000000000000000000000000000000000000") {
    throw new Error("NEW_RESOLUTION_MODULE must be set to a valid address");
  }
  
  return [
    {
      target: contractAddress,
      contractName: targetContractName,
      functionName: "proposeResolutionModule",
      args: [newResolutionModule],
      description: `Queue new resolution module: ${newResolutionModule}`,
    },
  ];
};

export default buildPayload;

