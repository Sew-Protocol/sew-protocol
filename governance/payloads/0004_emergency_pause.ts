/**
 * Payload: Emergency Pause (Emergency Lane)
 * 
 * Pauses the protocol in case of emergency.
 * This is an Emergency lane action (immediate execution, Guardian role).
 * 
 * Note: This requires Guardian multisig, not Timelock/DAO.
 */

import { PayloadBuilder } from "../../scripts/gov/types";
import { getDeployedAddress } from "../../scripts/gov/addresses";

export const metadata = {
  id: "0004_emergency_pause",
  title: "Emergency Pause Protocol",
  description: `
Pause the protocol in case of emergency.

This proposal pauses all escrow operations. This is an emergency action that:
- Can be executed immediately (no delay)
- Requires Guardian role (multisig)
- Can be reversed by Timelock via unpause()

**Warning**: Only use in genuine emergencies. This will halt all escrow operations.
  `,
  lane: "emergency" as const,
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
      functionName: "pause",
      args: [],
      description: `Emergency pause ${targetContractName}`,
    },
  ];
};

export default buildPayload;

