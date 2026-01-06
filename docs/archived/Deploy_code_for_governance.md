Approach

Fit a hardhat-deploy plan into your existing deploy/00_impl.ts, 10_proxy.ts, 90_post.ts structure without overhauling the repo.

Add a governance deployment slice that cleanly handles GovToken → Timelock → Governor → role grants → ownership transfers.

Keep it environment-driven (addresses + timings + guardian multisig) and compatible with both Hardhat tests and Foundry.

Hardhat deploy script outline (hardhat-deploy)

Below is a practical outline that you (or Cursor) can implement directly. It assumes:

fresh OZ Governor + TimelockController

single timelock delay = 48h

slow lane = 7d enforced in-contract via queue/activate (not by timelock)

guardian = multisig address

executor open (address(0)), canceller governor-only

0) Add deploy config conventions

Create deploy/_config.ts:

// deploy/_config.ts
import { HardhatRuntimeEnvironment } from "hardhat/types";

export type GovDeployConfig = {
  guardian: string;          // multisig
  feeRecipient: string;      // treasury / fee collector
  timelockMinDelaySec: number; // 48h = 172800
  votingDelayBlocks: number;
  votingPeriodBlocks: number;
  proposalThreshold: string; // token units
  quorumBps: number;         // e.g. 400 = 4% if using quorum fraction approach (or numerator/denom)
  initialGovTokenMints: Array<{ to: string; amount: string }>;
  // optional: existing deployments you want to reuse
};

export function getGovConfig(hre: HardhatRuntimeEnvironment): GovDeployConfig {
  const chainId = hre.network.config.chainId ?? 31337;

  // Defaults for local/dev; override via env for testnets/mainnet.
  const guardian = process.env.GUARDIAN_MULTISIG ?? hre.network.name === "hardhat"
    ? hre.ethers.Wallet.createRandom().address
    : "";

  const feeRecipient = process.env.FEE_RECIPIENT ?? guardian;

  // These should be tuned; these are reasonable placeholders.
  const timelockMinDelaySec = Number(process.env.TIMELOCK_MIN_DELAY_SEC ?? 48 * 60 * 60);

  const votingDelayBlocks = Number(process.env.GOV_VOTING_DELAY_BLOCKS ?? 1);
  const votingPeriodBlocks = Number(process.env.GOV_VOTING_PERIOD_BLOCKS ?? 45818); // ~1 week @ 13s
  const proposalThreshold = process.env.GOV_PROPOSAL_THRESHOLD ?? "0";
  const quorumBps = Number(process.env.GOV_QUORUM_BPS ?? 400); // 4%

  const initialGovTokenMints = (process.env.GOV_MINTS ?? "")
    .split(",")
    .filter(Boolean)
    .map((pair) => {
      const [to, amount] = pair.split(":");
      return { to, amount };
    });

  if (!guardian || guardian === "") {
    throw new Error("Missing GUARDIAN_MULTISIG env var for non-local networks.");
  }

  return {
    guardian,
    feeRecipient,
    timelockMinDelaySec,
    votingDelayBlocks,
    votingPeriodBlocks,
    proposalThreshold,
    quorumBps,
    initialGovTokenMints,
  };
}

1) Deploy GovToken (ERC20Votes)

Add deploy/20_gov_token.ts:

import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getGovConfig } from "./_config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, ethers, getNamedAccounts } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  const cfg = getGovConfig(hre);

  // You’ll implement GovToken.sol (ERC20Votes) if not already present.
  const govToken = await deploy("GovToken", {
    from: deployer,
    args: ["Intrinsic Governance Token", "INTRG"], // replace names
    log: true,
  });

  log(`GovToken deployed at ${govToken.address}`);

  // Optional: initial mints (for local/testnets). For mainnet you likely mint elsewhere.
  if (cfg.initialGovTokenMints.length > 0) {
    const token = await ethers.getContractAt("GovToken", govToken.address);
    for (const m of cfg.initialGovTokenMints) {
      const tx = await token.mint(m.to, m.amount);
      await tx.wait();
      log(`Minted ${m.amount} to ${m.to}`);
    }
  }
};

func.tags = ["governance", "govToken"];
export default func;


If you don’t want mint in deploy, remove it; just keep token deploy + delegation steps in 90_post.

2) Deploy TimelockController (48h)

Add deploy/30_timelock.ts:

import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getGovConfig } from "./_config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy, log, get } = deployments;
  const { deployer } = await getNamedAccounts();

  const cfg = getGovConfig(hre);

  // Start with no proposers; open executors; admin = deployer temporarily
  const timelock = await deploy("TimelockController", {
    from: deployer,
    args: [cfg.timelockMinDelaySec, [], ["0x0000000000000000000000000000000000000000"], deployer],
    log: true,
  });

  log(`TimelockController deployed at ${timelock.address}`);
};

func.tags = ["governance", "timelock"];
func.dependencies = ["govToken"];
export default func;

3) Deploy Governor (OZ GovernorTimelockControl)

Add deploy/40_governor.ts:

import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getGovConfig } from "./_config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy, log, get } = deployments;
  const { deployer } = await getNamedAccounts();

  const cfg = getGovConfig(hre);

  const govToken = await get("GovToken");
  const timelock = await get("TimelockController");

  // You’ll implement GovGovernor.sol with OZ Governor + extensions.
  const governor = await deploy("GovGovernor", {
    from: deployer,
    args: [
      govToken.address,
      timelock.address,
      cfg.votingDelayBlocks,
      cfg.votingPeriodBlocks,
      cfg.proposalThreshold,
      cfg.quorumBps,
    ],
    log: true,
  });

  log(`Governor deployed at ${governor.address}`);
};

func.tags = ["governance", "governor"];
func.dependencies = ["timelock"];
export default func;

4) Wire Timelock roles + harden (Governor proposer/canceller; revoke deployer admin)

Add deploy/50_timelock_wiring.ts:

import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, ethers, getNamedAccounts } = hre;
  const { log, get } = deployments;
  const { deployer } = await getNamedAccounts();

  const timelockDep = await get("TimelockController");
  const governorDep = await get("GovGovernor");

  const timelock = await ethers.getContractAt("TimelockController", timelockDep.address);

  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  const CANCELLER_ROLE = await timelock.CANCELLER_ROLE();
  const TIMELOCK_ADMIN_ROLE = await timelock.TIMELOCK_ADMIN_ROLE();

  // grant proposer/canceller to governor
  await (await timelock.grantRole(PROPOSER_ROLE, governorDep.address)).wait();
  await (await timelock.grantRole(CANCANCELLER_ROLE ?? CANCELLER_ROLE, governorDep.address)).wait().catch(async () => {
    // some OZ versions name it CANCELLER_ROLE; keep this defensive
    await (await timelock.grantRole(CANCELLER_ROLE, governorDep.address)).wait();
  });

  // OPTIONAL: set admin to timelock itself by granting admin role to itself
  // (depends on OZ version / role admin relationships)
  await (await timelock.grantRole(TIMELOCK_ADMIN_ROLE, timelockDep.address)).wait();

  // revoke deployer admin
  await (await timelock.revokeRole(TIMELOCK_ADMIN_ROLE, deployer)).wait();

  log(`Timelock wired: Governor is proposer+canceller; deployer admin revoked`);
};

func.tags = ["governance", "timelockWiring"];
func.dependencies = ["governor"];
export default func;


Note: OZ role constants differ slightly by version; in implementation, keep a single path with the correct constant names from your installed OZ.

5) Transfer protocol ownership/roles to Timelock + grant Guardian

This should live in your deploy/90_post.ts (or add a new deploy/60_protocol_governance.ts that runs after core deployments).

Assumptions for your contracts

If currently Ownable, do:

transferOwnership(timelock)

If you refactor to AccessControl, do:

grantRole(ROLE_TIMELOCK, timelock)

grantRole(ROLE_GUARDIAN, guardian)

revoke deployer roles

Outline:

import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getGovConfig } from "./_config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, ethers, getNamedAccounts } = hre;
  const { log, get, getOrNull } = deployments;
  const { deployer } = await getNamedAccounts();

  const cfg = getGovConfig(hre);

  const timelock = (await get("TimelockController")).address;

  // Example: transfer ownership for Ownable contracts
  const maybeTransfer = async (name: string) => {
    const dep = await getOrNull(name);
    if (!dep) return;

    const c = await ethers.getContractAt(name, dep.address);
    if (typeof (c as any).owner === "function") {
      const owner = await (c as any).owner();
      if (owner.toLowerCase() !== timelock.toLowerCase()) {
        await (await (c as any).transferOwnership(timelock)).wait();
        log(`${name}: ownership transferred to timelock`);
      }
    }
  };

  await maybeTransfer("BaseEscrow");
  await maybeTransfer("EscrowVault");
  await maybeTransfer("EscrowableERC20");
  await maybeTransfer("AaveYieldGenerationModule");
  await maybeTransfer("DefaultResolutionModule");
  await maybeTransfer("DecentralizedResolutionModule");
  // ... and any others you deploy

  // If AccessControl-based:
  // await c.grantRole(ROLE_TIMELOCK, timelock)
  // await c.grantRole(ROLE_GUARDIAN, cfg.guardian)

  log("Protocol governance handoff complete.");
};

func.tags = ["governance", "handoff"];
func.dependencies = ["timelockWiring"];
export default func;

6) Fit into your existing deploy order

You currently have:

00_impl.ts

10_proxy.ts

90_post.ts

Suggested integration:

Keep 00_impl.ts and 10_proxy.ts for protocol deployments if you still use them.

Add governance scripts with numeric ordering so hardhat-deploy runs in order:

Recommended files:

20_gov_token.ts

30_timelock.ts

40_governor.ts

50_timelock_wiring.ts

60_resolution_router.ts (optional if you deploy it here)

90_post.ts (handoff ownership/roles + set guardian + initial config)

If you are removing proxies, you can keep 10_proxy.ts but gate it by network tag, or skip it by tags.

7) Minimal governance contracts you’ll need to add

You’ll need to add contracts/governance/:

GovToken.sol (ERC20Votes + minting policy)

GovGovernor.sol (Governor + TimelockControl)

(If you want, I can provide these exact Solidity files next; I didn’t paste them here to keep focus on deploy wiring.)

Assumptions

You want EXECUTOR_ROLE open (address(0)), and canceller Governor-only, matching the governance.md.

Your deployed protocol contracts are either Ownable now or can be migrated to AccessControl with ROLE_TIMELOCK and ROLE_GUARDIAN.

You will enforce Slow=7d via queue/activate in-contract (not via timelock).

Next steps

I can provide the exact Solidity for GovToken.sol and GovGovernor.sol compatible with your chosen OZ version.

I can refactor the above outline into a single cohesive set of deploy scripts that align to your tags (--tags governance and --tags protocol).

I can produce a “handoff checklist” that verifies the end state onchain (roles, owners, pausability, caps, etc).

What I need from you

Which OpenZeppelin version are you using in package.json (e.g., @openzeppelin/contracts and @openzeppelin/contracts-governance)?

Are you keeping any of your current 10_proxy.ts proxy deployment, or do you want the governance scripts to assume no proxies?
