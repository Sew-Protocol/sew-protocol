Approach

Summarize how top Ethereum projects structure deployments + governance ops + emergency drills so changes are safe, repeatable, and muscle-memory for the team.

Translate those norms into a modular repo/workflow blueprint you can drop into your Hardhat + Foundry setup.

Include concrete patterns for upgrade sequences, proposal payloads, simulations, fork tests, and interactive execution across dev/testnet/mainnet.

What the best projects do (norms + patterns)
1) Treat governance changes as “releases” with the same discipline as software shipping

Top protocols don’t “run a script”; they ship a proposal package:

a payload (the exact calldata/actions)

a simulation report (fork/testnet)

a runbook (queue → execute → verify)

a backout/emergency plan (what guardian can do if something breaks)

This aligns with how major governance systems work: proposals get queued and executed via timelocks after delay windows (Uniswap/Compound), and execution is intentionally open after timelock expiry (any address can execute). 
Uniswap Docs
+2
Compound III Documentation
+2

2) Separate “proposal intent” from “execution environment”

The strongest teams keep the “what we intend to do” as a portable artifact, and then have thin wrappers to run it:

payload builders: generate targets/values/calldatas

executors: dev (impersonate timelock), testnet (actual timelock), mainnet (queue/execute)

Aave explicitly distinguishes different executors/timelocks (short vs long) with different delays, and provides a “payload registration/execution” concept. 
aave.com
+2
aave.com
+2

3) Make upgrade/emergency procedures routine via repeatable drills

Best teams run “governance fire drills”:

simulate a proposal end-to-end (create → vote → queue → execute)

simulate emergency response (pause, disable deposits, reduce caps)

verify post-conditions (invariants and onchain state)

Aave even has public repos that test “proposal created/queued/voted/executed” flows for timelocks, demonstrating the norm of testing the governance lifecycle itself, not only the protocol code. 
GitHub

OpenZeppelin also ships Foundry tests validating the correctness of proposal lifecycle behavior for Governor-style systems. 
GitHub

4) Use a “short vs long lane” mindset, even if you implement it in one timelock

Many best-in-class systems have differentiated execution paths for normal vs high-privilege changes (Aave short vs long executors/timelocks). 
aave.com
+1

In your case (single timelock), you’re replicating the same idea via:

Standard: timelock (48h)

Slow: queue/activate (7d) on top

That’s conceptually aligned with what people already understand.

5) Simulate everything on forks; use interactive tools for final confidence

The norm is:

run the proposal on a mainnet fork with realistic state

then optionally run it on a testnet staging deployment

for multisig/timelock actions, teams increasingly use simulation tooling (e.g., Safe simulations in Tenderly) as an additional safety layer 
Blog | Tenderly

manage roles and timelock ops with clear tooling (OZ Defender docs emphasize workflows for timelock role management and proposals). 
OpenZeppelin Docs

A modular blueprint you can adopt (Hardhat + Foundry)

Below is the pattern you’ll see in well-run projects, adapted to your repo and your goals (interactive, testable, clear).

A) Directory layout (adds, doesn’t break your current structure)
/governance
  /proposals
    0001_enable-aave.json
    0002_swap-resolution-module.json
    0003_raise-token-cap.json
  /payloads
    0001_enable-aave.ts
    0002_swap-resolution-module.ts
    0003_raise-token-cap.ts
  /runbooks
    0001_enable-aave.md
    0002_swap-resolution-module.md
  /checks
    postChecks.ts
    invariants.ts

/scripts
  /gov
    build-proposal.ts
    simulate-fork.ts
    queue.ts
    execute.ts
    emergency.ts


Key idea: every change has:

a payload builder (payloads/*.ts)

a serialized artifact (proposals/*.json)

a runbook and post-checks.

B) “Proposal artifact” format (portable)

A JSON artifact that both Hardhat and Foundry can consume:

{
  "id": "0002",
  "title": "Swap Resolution Module via queue/activate",
  "chainId": 8453,
  "targets": ["0x..."],
  "values": ["0"],
  "calldatas": ["0x..."],
  "description": "..."
}


This mirrors how Uniswap/Compound style governance is expressed (targets/values/calldatas queued into timelock). 
Uniswap Docs
+1

C) Environment adapters (dev / testnet / mainnet)

Provide a single interface:

getSigner(mode):

dev/fork: impersonate timelock/governor/guardian

testnet: use actual deployer keys for proposals + real timelock

mainnet: read-only + propose via Governor; execute after delay

getAddresses(chainId):

load from deployments/<network>/...json (hardhat-deploy)

plus config overlay (guardian multisig, fee recipient)

D) Governance lifecycle tests (muscle-memory)

Create three “golden path” test suites:

Standard parameter change (48h)

propose → vote → queue → execute

validate bounds enforcement & events

Slow-lane change (~9d wall-clock)

proposal #1 queues pending change

time jump 7d

proposal #2 activates

verify “new escrows only”

Emergency drill

guardian pauses

guardian disables Aave deposits

guardian lowers cap

timelock unpauses (48h)

ensure guardian cannot re-enable or raise caps

This matches real protocol governance expectations that changes flow through timelock queue/execute phases. 
OpenZeppelin Docs
+1

How to make it interactive (without becoming messy)
1) A single CLI entrypoint with subcommands

Example:

pnpm gov:build 0002

pnpm gov:sim 0002 --fork mainnet

pnpm gov:queue 0002 --network baseSepolia

pnpm gov:execute 0002 --network baseSepolia

pnpm gov:emergency disable-aave --network baseSepolia

pnpm gov:check 0002 --network baseSepolia

This gives you:

repeatability

low cognitive load

a consistent “ritual” for upgrades and emergencies

2) Make “post-checks” first-class

Every proposal should ship with an executable post-check:

state variables changed as expected

events emitted

caps unchanged except intended

invariants still hold

3) Use forks as your default staging

Best teams practice on mainnet forks because:

the state is realistic (liquidity, balances, aToken mappings, etc.)

you catch integration issues earlier than on sterile testnets

4) Keep runbooks short and executable

A runbook should be:

a numbered sequence

with exact commands to run

and expected outputs / checks

Aave’s governance process docs emphasize stages around queueing/executing after timelock and the need to execute before expiry windows; your runbooks should reflect the same operational awareness. 
Aave
+1

What this looks like for your specific protocol surfaces
Upgrade practice scenarios you should rehearse monthly

Swap Resolution Module (Slow)

queue new module

wait 7d

activate

confirm new escrows use it; old escrows don’t

Reduce Aave risk (Emergency + Standard)

guardian disables Aave deposits

guardian lowers token cap

timelock later re-enables Aave (if desired) and adjusts caps (bounded)

Fee recipient change (Slow)

queue new fee recipient

activate later

ensure fee withdraw role remains constrained

Rollout BPS adjustment (Standard, bounded)

adjust rollout within bounds

verify only new escrows affected (because you snapshot selected impl at creation)

Assumptions

You want “fork-first” simulation as your primary confidence mechanism.

You’ll treat governance actions as artifacts (payload + JSON + runbook + checks), not ad-hoc scripts.

Your “new escrows only” rule is enforced by snapshotting chosen modules/settings at escrow creation.

Next steps

I can draft the actual scripts/gov/* CLI files (build/sim/queue/execute/emergency/check) aligned to hardhat-deploy deployments.

I can propose 3–5 initial proposal templates that match your real actions: fee bps change, module swap, cap reduction, enable Aave, update resolver.

I can outline a governance drill schedule (monthly/quarterly) with checklists so the team builds muscle memory.

What I need from you

Which networks are you targeting for staging: Base Sepolia, Ethereum Sepolia, both, or something else?

Do you want the interactive tooling to run primarily via Hardhat scripts, or do you also want Foundry scripts (forge script) for fork simulations?

Suggested next step

Tell me your staging network(s) and whether you prefer Hardhat-only or Hardhat+Foundry for the interactive tooling, and I’ll generate the initial /scripts/gov scaffold plus the first two proposal templates.





Approach

Define a single, clean “proposal artifact” format that both Hardhat scripts and Foundry scripts/tests can consume.

Provide a repo scaffold for /scripts/gov that supports: build → simulate (fork) → stage (Base Sepolia) → queue/execute → post-checks, plus emergency drills.

Give you 2 starter proposals (Standard + Slow) and the corresponding Hardhat + Foundry entrypoints.

Recommended workflow (Base Sepolia + Hardhat + Foundry)
Daily/normal changes (Standard lane)

pnpm gov:build 0001

pnpm gov:sim:hh 0001 --fork base (Hardhat fork)

pnpm gov:sim:forge 0001 --fork base (Foundry fork, more invariant-heavy)

pnpm gov:stage 0001 --network baseSepolia (submit proposal / queue / execute depending on phase)

pnpm gov:check 0001 --network baseSepolia

High-impact changes (Slow lane)

Same flow, but:

proposal A queues the change

wait 7d

proposal B activates
And you drill both on forks regularly.

1) Scaffold: folders and files to add

Add:

/governance
  /payloads
    0001_set_token_cap.ts
    0002_queue_resolution_module.ts
    0003_activate_resolution_module.ts
  /proposals
    0001_set_token_cap.base-sepolia.json
    0002_queue_resolution_module.base-sepolia.json
    0003_activate_resolution_module.base-sepolia.json
  /runbooks
    0001_set_token_cap.md
    0002_0003_resolution_swap.md
  /checks
    0001_postcheck.ts
    0002_postcheck.ts
    0003_postcheck.ts

/scripts
  /gov
    addresses.ts
    artifact.ts
    build-proposal.ts
    simulate-hardhat.ts
    queue-execute.ts
    stage.ts
    check.ts
    emergency.ts

/test
  /hardhat
    governance.lifecycle.spec.ts
  /foundry
    governance
      GovForkSim.t.sol
      GovInvariants.t.sol

2) Proposal artifact format (single source of truth)

Create scripts/gov/artifact.ts:

export type ProposalArtifact = {
  id: string;
  title: string;
  chainId: number;
  createdAt: string;
  description: string;

  targets: string[];
  values: string[];     // wei as string
  calldatas: string[];  // hex
};


This mirrors how governance systems ultimately encode proposals: targets/values/calldatas.

3) Addresses resolver (hardhat-deploy compatible)

scripts/gov/addresses.ts:

import fs from "fs";
import path from "path";

export type GovAddresses = {
  GovToken: string;
  GovGovernor: string;
  TimelockController: string;

  // protocol contracts/modules you touch in proposals:
  AaveYieldGenerationModule?: string;
  BaseEscrow?: string;
  EscrowVault?: string;
  ResolutionRouter?: string;
};

export function loadAddresses(networkName: string): GovAddresses {
  const p = path.join(process.cwd(), "deployments", networkName);
  const read = (name: string) => {
    const fp = path.join(p, `${name}.json`);
    if (!fs.existsSync(fp)) return undefined;
    const j = JSON.parse(fs.readFileSync(fp, "utf8"));
    return j.address as string;
  };

  return {
    GovToken: read("GovToken")!,
    GovGovernor: read("GovGovernor")!,
    TimelockController: read("TimelockController")!,
    AaveYieldGenerationModule: read("AaveYieldGenerationModule"),
    BaseEscrow: read("BaseEscrow"),
    EscrowVault: read("EscrowVault"),
    ResolutionRouter: read("ResolutionRouter"),
  };
}

4) Build step: payload → artifact JSON

scripts/gov/build-proposal.ts (outline):

import fs from "fs";
import path from "path";
import { ethers } from "ethers";
import { ProposalArtifact } from "./artifact";
import { loadAddresses } from "./addresses";

async function main() {
  const id = process.argv[2]; // "0001"
  const networkName = process.env.GOV_NETWORK ?? "baseSepolia";
  const chainId = Number(process.env.GOV_CHAIN_ID ?? 84532); // Base Sepolia

  const addrs = loadAddresses(networkName);

  // Dynamically import payload builder
  const payload = await import(path.join(process.cwd(), "governance", "payloads", `${id}_*.ts`)).catch(() => null);
  // In practice: map id->filename or glob; keep it explicit to avoid magic.
  // Example below assumes explicit file names; simplest.

  let built: Omit<ProposalArtifact, "createdAt">;

  if (id === "0001") {
    const { build0001 } = await import("../../governance/payloads/0001_set_token_cap");
    built = await build0001({ chainId, addrs, ethers });
  } else if (id === "0002") {
    const { build0002 } = await import("../../governance/payloads/0002_queue_resolution_module");
    built = await build0002({ chainId, addrs, ethers });
  } else if (id === "0003") {
    const { build0003 } = await import("../../governance/payloads/0003_activate_resolution_module");
    built = await build0003({ chainId, addrs, ethers });
  } else {
    throw new Error(`Unknown proposal id: ${id}`);
  }

  const artifact: ProposalArtifact = {
    ...built,
    createdAt: new Date().toISOString(),
  };

  const out = path.join(process.cwd(), "governance", "proposals", `${id}.${networkName}.json`);
  fs.writeFileSync(out, JSON.stringify(artifact, null, 2));
  console.log(`Wrote: ${out}`);
}

main().catch((e) => { console.error(e); process.exit(1); });


You’ll likely keep an explicit mapping id -> payload filename for clarity.

5) Starter payload builders (2 examples)
5.1 Proposal 0001 (Standard): set token cap (timelock)

governance/payloads/0001_set_token_cap.ts:

import { Interface } from "ethers";

export async function build0001({ chainId, addrs, ethers }: any) {
  const title = "Set Aave token cap (raw units)";
  const description = "Standard lane: set cap for a token in AaveYieldGenerationModule (timelock-only).";

  const mod = addrs.AaveYieldGenerationModule;
  if (!mod) throw new Error("Missing AaveYieldGenerationModule deployment");

  // Example function signature — match your contract:
  const iface = new Interface(["function setTokenCap(address token,uint256 newCap)"]);

  const token = process.env.CAP_TOKEN!;
  const cap = process.env.CAP_AMOUNT!; // string (wei units)

  return {
    id: "0001",
    title,
    chainId,
    description,
    targets: [mod],
    values: ["0"],
    calldatas: [iface.encodeFunctionData("setTokenCap", [token, cap])],
  };
}

5.2 Proposal 0002/0003 (Slow): queue/activate resolution module

governance/payloads/0002_queue_resolution_module.ts:

import { Interface } from "ethers";

export async function build0002({ chainId, addrs }: any) {
  const title = "Queue new resolution module";
  const description = "Slow lane step 1: queue pending resolution module change (eta=now+7d).";

  const baseEscrow = addrs.BaseEscrow;
  if (!baseEscrow) throw new Error("Missing BaseEscrow deployment");

  const iface = new Interface(["function proposeResolutionModule(address newModule)"]);

  const newModule = process.env.NEW_RESOLUTION_MODULE!;
  return {
    id: "0002",
    title,
    chainId,
    description,
    targets: [baseEscrow],
    values: ["0"],
    calldatas: [iface.encodeFunctionData("proposeResolutionModule", [newModule])],
  };
}


governance/payloads/0003_activate_resolution_module.ts:

import { Interface } from "ethers";

export async function build0003({ chainId, addrs }: any) {
  const title = "Activate queued resolution module";
  const description = "Slow lane step 2: activate resolution module after eta.";

  const baseEscrow = addrs.BaseEscrow;
  if (!baseEscrow) throw new Error("Missing BaseEscrow deployment");

  const iface = new Interface(["function activateResolutionModule()"]);

  return {
    id: "0003",
    title,
    chainId,
    description,
    targets: [baseEscrow],
    values: ["0"],
    calldatas: [iface.encodeFunctionData("activateResolutionModule", [])],
  };
}

6) Hardhat fork simulation (fast feedback)

scripts/gov/simulate-hardhat.ts outline:

reset fork to Base mainnet (or Base Sepolia fork—typically you fork mainnet for realism; but you chose Base Sepolia staging, so for parity you can fork Base Sepolia too)

impersonate TimelockController executor to “execute after delay”

run proposal calldata directly against forked state

run post-checks

Key trick:

for timelock flows, impersonate timelock and call the target directly for “effect simulation”

separately, you can fully simulate queue -> execute by calling timelock methods, but it’s more setup.

7) Foundry fork simulation (governance + invariants)

Add test/foundry/governance/GovForkSim.t.sol:

load artifact JSON (Foundry can read via vm.readFile)

decode targets/values/calldatas

vm.prank(timelock) and call each

run invariants after

This is how strong teams get “E2E governance confidence” quickly: Foundry fork tests are fast and realistic.

8) Stage runner for Base Sepolia (real queue/execute)

scripts/gov/stage.ts should support phases:

propose: submit proposal to Governor with artifact payload

queue: queue via Governor after vote passes

execute: execute via Governor after timelock passes

In practice, on Base Sepolia you’ll often shortcut voting by:

holding majority supply in a test wallet

delegating to yourself

using short voting periods for staging

Your scripts should print:

proposalId

ETA / timestamps

next command to run

9) Emergency runner (guardian drill)

scripts/gov/emergency.ts commands:

pause

disable-aave

lower-cap --token ... --cap ...
All signed by guardian key (on dev/fork you impersonate guardian; on testnet you use the multisig).

Critically:

unpause is excluded here; that stays in gov pipeline.

10) package.json scripts (suggested)
{
  "scripts": {
    "gov:build": "ts-node scripts/gov/build-proposal.ts",
    "gov:sim:hh": "ts-node scripts/gov/simulate-hardhat.ts",
    "gov:sim:forge": "forge test -C . -m GovForkSim --fork-url $BASE_RPC",
    "gov:stage": "ts-node scripts/gov/stage.ts",
    "gov:check": "ts-node scripts/gov/check.ts",
    "gov:emergency": "ts-node scripts/gov/emergency.ts"
  }
}

Assumptions

You’ll use hardhat-deploy’s deployments/<network> as the canonical address book.

You’re comfortable keeping proposal IDs explicit (0001/0002/0003) instead of auto-generated discovery.

Your governed functions accept timelock calls directly (i.e., onlyRole(ROLE_TIMELOCK)).

Next steps

I can generate a complete minimal GovToken.sol + GovGovernor.sol pair compatible with OZ GovernorTimelockControl.

I can write the initial Hardhat stage runner that handles propose/queue/execute and prints next actions cleanly.

I can write the Foundry GovForkSim.t.sol that reads the JSON artifact and executes it via vm.prank(timelock) plus post-check hooks.

What I need from you

Do you want to fork/simulate against Base mainnet for realism, or Base Sepolia for exact parity with staging?

What’s your preferred voting config for staging: short (minutes) or realistic (days)?

Suggested next step

Answer “fork base mainnet vs sepolia” and “staging voting short vs realistic,” and I’ll generate the stage runner outline + the Foundry fork test skeleton that reads proposal JSON artifacts.
