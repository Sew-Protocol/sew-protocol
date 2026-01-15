# Proposal Payloads

Reusable payload builders for common governance actions.

## Structure

Each payload file exports:

- `default` or `buildPayload`: Function that returns `ProposalCall[]`
- `metadata`: Object with proposal metadata

## Example

```typescript
import { PayloadBuilder } from '../../scripts/gov/types';
import { getDeployedAddress } from '../../scripts/gov/addresses';

export const metadata = {
  id: '0001_set_token_cap',
  title: 'Set Token Cap for USDC',
  description: 'Set a cap of 10M USDC for Aave yield generation',
  lane: 'standard',
  requiredContracts: ['AaveYieldGenerationModule'],
};

const buildPayload: PayloadBuilder = async (hre, config) => {
  const aaveModule = await getDeployedAddress(hre, 'AaveYieldGenerationModule');
  const usdcAddress = config?.usdcAddress || '0x...'; // Default or from config

  return [
    {
      target: aaveModule,
      contractName: 'AaveYieldGenerationModule',
      functionName: 'setTokenCap',
      args: [usdcAddress, hre.ethers.parseUnits('10000000', 6)], // 10M USDC
      description: 'Set USDC cap to 10M',
    },
  ];
};

export default buildPayload;
```

## Naming Convention

- `0001_<action>.ts` - Sequential numbering
- Descriptive action names (e.g., `set_token_cap`, `queue_fee_address`)
