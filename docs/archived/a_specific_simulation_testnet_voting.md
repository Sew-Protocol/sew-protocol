Approach

Lock in a staging-first setup: Base Sepolia fork + minute-scale voting so you can rehearse governance flows repeatedly.

Provide a concrete config (blocks → minutes), plus a Hardhat stage runner outline that supports propose → vote → queue → execute.

Add a Foundry fork test skeleton that reads the proposal JSON artifact and runs it against the fork with post-check hooks.

1) Staging voting config (minutes)

Base Sepolia block times vary, but for staging you mainly want speed and repeatability. A robust approach is to express voting in blocks, tuned to be “minutes-ish”:

Suggested defaults:

votingDelayBlocks = 1 (proposal becomes active next block)

votingPeriodBlocks = 50 (roughly ~10 minutes if blocks ~12s; adjust as needed)

proposalThreshold = 0 (so you can propose easily in staging)

quorumBps = 1 or small (and you hold enough delegated votes to pass)

In staging you’ll:

mint a large share to your staging signer

delegate to self

vote and queue/execute quickly

2) Hardhat stage runner outline (propose → vote → queue → execute)

Create scripts/gov/stage.ts with subcommands:

Commands

pnpm gov:stage propose 0001 --network baseSepolia

pnpm gov:stage vote 0001 --network baseSepolia

pnpm gov:stage queue 0001 --network baseSepolia

pnpm gov:stage execute 0001 --network baseSepolia

pnpm gov:stage full 0001 --network baseSepolia (does propose+vote+queue+execute with waits)

Core behaviors

Load artifact JSON: governance/proposals/0001.baseSepolia.json

Compute proposal description hash exactly as Governor expects

Use Governor methods:

propose(targets, values, calldatas, description)

castVote(proposalId, 1) (For)

queue(targets, values, calldatas, descriptionHash)

execute(targets, values, calldatas, descriptionHash)

Outline code (high-level but implementable)
// scripts/gov/stage.ts
import fs from "fs";
import path from "path";
import { ethers, network } from "hardhat";
import { loadAddresses } from "./addresses";
import { ProposalArtifact } from "./artifact";

function loadArtifact(id: string, net: string): ProposalArtifact {
  const fp = path.join(process.cwd(), "governance", "proposals", `${id}.${net}.json`);
  return JSON.parse(fs.readFileSync(fp, "utf8"));
}

async function main() {
  const cmd = process.argv[2]; // propose|vote|queue|execute|full
  const id  = process.argv[3]; // 0001
  const netName = process.env.GOV_NETWORK ?? "baseSepolia";

  const addrs = loadAddresses(netName);
  const art = loadArtifact(id, netName);

  const governor = await ethers.getContractAt("GovGovernor", addrs.GovGovernor);
  const token = await ethers.getContractAt("GovToken", addrs.GovToken);

  const [signer] = await ethers.getSigners();
  // Ensure delegation (staging convenience)
  const del = await token.delegates(await signer.getAddress());
  if (del.toLowerCase() !== (await signer.getAddress()).toLowerCase()) {
    await (await token.delegate(await signer.getAddress())).wait();
    console.log("Delegated votes to self");
  }

  const descHash = ethers.keccak256(ethers.toUtf8Bytes(art.description));

  if (cmd === "propose" || cmd === "full") {
    const tx = await governor.propose(art.targets, art.values, art.calldatas, art.description);
    const rc = await tx.wait();
    const ev = rc!.logs.find((l: any) => l.fragment?.name === "ProposalCreated");
    console.log("Proposed:", rc?.hash);
    // You can also read proposalId from event; easiest is call governor.hashProposal(...)
  }

  const proposalId = await governor.hashProposal(art.targets, art.values, art.calldatas, descHash);
  console.log("proposalId:", proposalId.toString());

  if (cmd === "vote" || cmd === "full") {
    // Move to active if needed
    const state = await governor.state(proposalId);
    // If Pending, mine blocks (staging)
    if (state === 0n) {
      await network.provider.send("hardhat_mine", ["0x2"]); // two blocks
    }
    await (await governor.castVote(proposalId, 1)).wait(); // 1 = For
    console.log("Voted For");
  }

  if (cmd === "queue" || cmd === "full") {
    // Ensure voting period finished for staging; mine enough blocks
    const vpb = await governor.votingPeriod();
    await network.provider.send("hardhat_mine", ["0x" + (Number(vpb) + 2).toString(16)]);
    await (await governor.queue(art.targets, art.values, art.calldatas, descHash)).wait();
    console.log("Queued");
  }

  if (cmd === "execute" || cmd === "full") {
    // Wait timelock (Base Sepolia real time on-chain) — in fork you can warp; on testnet you actually wait.
    await (await governor.execute(art.targets, art.values, art.calldatas, descHash)).wait();
    console.log("Executed");
  }
}

main().catch((e) => { console.error(e); process.exit(1); });


Notes

On real Base Sepolia, you cannot hardhat_mine. The full mode is mainly for fork rehearsal; on testnet you’ll run propose/vote/queue/execute as separate commands over time.

For staging “minutes”, set the Governor voting period low; timelock still enforces 48h, so queue/execute is not “minutes” unless you’re on a fork. That’s fine: staging aims to train the whole lifecycle; forks give you rapid drills.

3) Hardhat fork simulation (Base Sepolia)

Add scripts/gov/simulate-hardhat.ts:

fork Base Sepolia RPC

impersonate accounts as needed

run the full lifecycle fast by:

mining blocks for voting

increasing time by 48h for timelock

for Slow lane: increase time by 7d between queue/activate proposals

Key RPC helpers:

evm_increaseTime

evm_mine

hardhat_impersonateAccount (if needed)

4) Foundry fork test (reads JSON artifact)

Create test/foundry/governance/GovForkSim.t.sol:

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IGovernor {
  function propose(address[] memory, uint256[] memory, bytes[] memory, string memory) external returns (uint256);
  function castVote(uint256 proposalId, uint8 support) external returns (uint256);
  function queue(address[] memory, uint256[] memory, bytes[] memory, bytes32 descriptionHash) external returns (uint256);
  function execute(address[] memory, uint256[] memory, bytes[] memory, bytes32 descriptionHash) external payable returns (uint256);
  function state(uint256 proposalId) external view returns (uint8);
  function hashProposal(address[] memory, uint256[] memory, bytes[] memory, bytes32 descriptionHash) external view returns (uint256);
}

contract GovForkSim is Test {
  function test_simulateProposal0001() external {
    // 1) Read artifact JSON from governance/proposals/0001.baseSepolia.json
    string memory p = string.concat(vm.projectRoot(), "/governance/proposals/0001.baseSepolia.json");
    string memory json = vm.readFile(p);

    // 2) Extract fields (Foundry supports JSON parsing)
    address governor = vm.parseJsonAddress(json, ".governor"); // if you add it
    // Alternatively: pass governor via env or hardcode staging deployment address.

    // You can also parse arrays:
    // bytes memory targetsRaw = vm.parseJson(json, ".targets"); etc.

    // 3) For now, keep fork sims driven by env:
    // - GOV_GOVERNOR
    // - GOV_TIMELOCK
    // - PROPOSER / VOTER private key

    // This file is a skeleton; once you decide whether to embed governor/timelock in JSON,
    // we can complete parsing for arrays and full execution.

    assertTrue(true);
  }
}


Practical improvement: include governor and timelock fields in the artifact JSON for Foundry convenience, or pass them via env. I recommend embedding them for staging artifacts.

5) Make “minute drills” real despite 48h timelock

On fork (fast drills):

mine blocks to finish voting

evm_increaseTime(48h + 1)

execute immediately
This gives you “minutes” cadence for full lifecycle rehearsal.

On Base Sepolia (staging reality):

governance votes can finish in minutes

timelock still takes 48h
That’s okay: your team rehearses:

“we queued it; here’s the ETA; here’s the checklist we do during the delay”

For purely procedural muscle memory, forks are the “minutes mode.” Sepolia is your “real chain rehearsal.”

Assumptions

You’re okay using forks for fast drills and Base Sepolia for realistic staged execution.

Your staging Governor parameters will be set for short voting periods and low thresholds.

You’ll add a small amount of metadata to artifacts (addresses) or provide them via env for Foundry parsing.

Next steps

I can write the complete scripts/gov/simulate-hardhat.ts that runs propose→vote→queue→timewarp→execute on a Base Sepolia fork.

I can finalize the Foundry JSON parsing and make GovForkSim.t.sol execute the artifact payload directly, plus add a GovInvariants.t.sol.

I can propose two initial runbooks (0001_set_token_cap.md, 0002_0003_resolution_swap.md) matching the scripts.

What I need from you

Do you want proposal artifacts to include governor, timelock, and chainName fields (makes Foundry parsing easier)?

For fork drills, do you prefer impersonating the proposer/voter, or using a local fork wallet key that holds delegated votes?

Suggested next step

Say “include addresses” (or “keep minimal”) and “impersonate” (or “local key”), and I’ll generate the full simulate-hardhat script + completed Foundry fork test.
