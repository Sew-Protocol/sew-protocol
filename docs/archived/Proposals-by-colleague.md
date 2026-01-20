## Consider this document as 'proposals by a colleague llm', rather than set instructions

We don't want to rename yet so we dont introducing breaking changes to our wallet app. (although not yet deployed to production or mainnet, so we can make changes we need to)




# Escrow Standard & Next Contract Iteration (Everyday Wallet / iWallet)

This document proposes the next iteration of the iWallet escrow contract system and explores options for standardizing escrow (and dispute resolution) as ERC-style standards.

It is written with a concrete understanding of:
- The current on-chain reference contract: `references/EscrowableERC20.sol`
- The Everyday Wallet interaction model: `hooks/blockchain/useEscrow.ts`, `adapters/chain/ChainGateway.ts`, `services/EscrowActionService.ts`, and `utils/escrowStatus.ts`
- The emerging direction for modular escrow extensions (group consensus): `contracts/GroupEscrowExtension.sol`

---

## 1) Executive summary

### Core recommendation

Adopt **two standards** as the primary public-facing standardization strategy:

- **Escrow Core Standard (ERC-ESCR-CORE)**: defines an escrow state machine, roles, custody, events, and minimal dispute hooks.
- **Dispute Resolution Standard (ERC-ESCR-DISPUTE)**: defines how disputes are opened, evidenced, and resolved, in a way that can be attached to any compliant escrow.

Then define a third “umbrella” standardization layer as **fully modular extensions** (optional EIP-165 interfaces), so your system can evolve without forcing every escrow to implement every feature.

### Why split escrow and dispute?

Everyday Wallet already has:
- **Escrow** as a broadly reusable workflow (create → pending → release/refund, with timeouts)
- **Dispute** as a policy / institution choice (authorized resolver address, optional partial resolution)
- **Off-chain messaging and UX** (Inbox) that is important but shouldn’t be baked into a chain standard

Splitting keeps the escrow standard “thin” and maximally adoptable, while still letting you ship an opinionated resolver standard and modules that the wallet can plug into.

---

## 2) Current system: what exists today

### 2.1 Current on-chain reference: `EscrowableERC20.sol`

The current contract is a **token contract (ERC20)** with **embedded escrow ledger**:



- **Escrow identity**: `workflowId` (`uint256`) from a monotonically-incrementing counter; escrow structs live in a public array `escrowTransfers`.
- **Custody**: funds are transferred into the token contract itself (`transfer(address(this), amount)`), then later paid out with `_transfer(address(this), ...)`.
- **Fee model**: a basis-point fee is computed at create time; escrow holds `amountAfterFee`, while the contract balance holds the full `amount`. Fees accrue to `totalFees` and can be withdrawn by `escrowFeeAddress`.
- **State machine**:
  - `PENDING` → `RELEASED` (sender releases)
  - `PENDING` → `CANCELLED` (two-step sender/recipient agreement)
  - `PENDING` → `DISPUTE` (either party can raise dispute)
  - `DISPUTE` → `RESOLVER_OVERRIDDEN` (resolver resolves/release/cancel/partial)
- **Attachments**: on-chain arrays of URIs + hashes; max attachments enforced.
- **Timeouts**: `autoReleaseTime` / `autoCancelTime`, but require external calls to trigger via `automateTimedActions`.

### 2.2 Everyday Wallet interaction model

In the app, escrow is treated as a “domain capability” behind a gateway:

- **On-chain API surface assumed by the app**: see `adapters/chain/types.ts` (`ChainGateway`), `hooks/blockchain/useEscrow.ts`, and `services/EscrowActionService.ts`.
- **AA support**: the chain layer supports ERC-4337-like execution by abstracting write calls (`writeContractWithAA`) and gating “write-capable gateway creation”.
- **Two-step cancel UX**:
  - Buyer requests refund (`senderCancel`)
  - Seller confirms (`recipientCancel`)
  - The Inbox is used to send action requests and context/comments.
- **Dispute UX**: `raiseDispute(workflowId)` plus resolver notification if the resolver is third-party.
- **Status presentation**: `utils/escrowStatus.ts` maps numeric states and derives higher-level labels like “Cancel requested”.

### 2.3 Notable contract ↔ wallet impedance mismatches (important for standard design)

These mismatches are directly relevant to standardization because they affect how indexers and wallets can reliably interpret escrow state:

1) **Event indexing / workflow id extraction**
   - The wallet currently attempts to parse `workflowId` from the `EscrowTransferCreated` event topics (assuming an indexed parameter) and falls back to `nextWorkflowId - 1` if parsing fails (`services/EscrowActionService.ts`).
   - Some deployed ABIs show `EscrowTransferCreated` parameters as **not indexed** (so `topics[1]` will not contain the id).
   - A standard must define **indexed event fields** for discoverability and safe parsing.

2) **State machine clarity**
   - Wallet logic derives composite UI states (“Cancel requested”) from `senderStatus` / `recipientStatus` while escrow is still pending.
   - A standard should either:
     - Encode those as explicit sub-states, or
     - Standardize the “role statuses” and define how to derive composite states.

3) **Cancel function naming**
   - The gateway has a `cancelEscrowTransfer()` method wired to a non-existent `cancelEscrowTransfer` function in the reference contract, while the wallet primarily uses `senderCancel`/`recipientCancel`.
   - A standard should define canonical names and role semantics.

/home/user/Code/iwallet/references/scaffold-eth

The internal function cancelAndRefund() initiates the refund / completes the cancellation
It's triggered when the contract detects that both parties have cancelled. (senderCancel and recipientCancel)

4) **Timeout execution**
   - A standard should acknowledge that timeouts are **pull-based** (anyone can call) unless there is an on-chain scheduler (not available on L1).
   - It should specify a canonical “execute timeout” method and event semantics.

Intend to enhance for use with gelato / keeper

---

## 3) Standardization goals (what “an escrow standard” should achieve)

An escrow standard should optimize for:

- **Interoperability**: any wallet/app can understand escrow state and render actions safely.
- **Indexability**: indexers can track escrow lifecycle from events without bespoke decoding.
- **Asset generality**: support ERC-20 at minimum; optionally ETH and ERC-721/1155.
- **Role generality**: support “payer/payee” (or “depositor/beneficiary”), not only “buyer/seller”.
- **Dispute pluggability**: disputes should not force a single arbitration mechanism.
- **AA compatibility**: avoid patterns that assume EOAs; support one-transaction flows where possible (permit/Permit2/meta-tx as optional extensions).
- **Composable upgrades**: allow timeouts, evidence, group authorization, and fees as extensions.

Non-goals for the on-chain standard:

- UI flows (Inbox messaging, comments, moderation UX)
- Off-chain identity / profiles
- Specific arbitration vendors or enforcement mechanisms

---

## 4) Option A: One escrow standard with embedded dispute resolution

### 4.1 Overview

A single ERC would define:
- Escrow creation and settlement
- Dispute opening and evidence submission
- Resolver selection and resolution execution
- Resolver authority model (who can rule, and how)

### 4.2 Pros

- **Simple integration**: one contract interface to support in wallets/indexers.
- **Uniform lifecycle**: “escrow+dispute” is a single lifecycle graph.
- **Predictable UX**: fewer combinations for apps to handle.

### 4.3 Cons

- **Harder adoption**: projects that want escrow but not disputes (or want custom disputes) may avoid it.
- **Governance complexity**: “dispute system” choices are political; standards should be minimal and optional where possible.
- **Innovation friction**: new dispute mechanisms (optimistic, jury, staking, ZK-based group consensus) become hard to incorporate.

### 4.4 What this looks like (conceptual interface)

Minimum “all-in-one” interface would standardize:
- `createEscrow(...) returns (escrowId)`
- `release(escrowId)`
- `requestCancel(escrowId)` / `confirmCancel(escrowId)`
- `openDispute(escrowId, disputeData)`
- `submitEvidence(escrowId, uri, hash)`
- `rule(escrowId, rulingData)` (resolver-only)

And events:
- `EscrowCreated`
- `EscrowStateChanged`
- `EvidenceSubmitted`
- `DisputeOpened`
- `DisputeRuled`

### 4.5 Embedded dispute resolver model

To avoid standardizing “a single resolver”, you’d still need an abstraction such as:
- A resolver address per escrow
- A registry of resolvers (optional)
- A standard callback interface for resolvers

Even with embedded disputes, you end up needing a dispute interface anyway—so embedded disputes often converge toward the split approach below.

---

## 5) Option B: One escrow standard and one dispute resolution standard

### 5.1 Overview

Define:

1) **ERC-ESCR-CORE** (Escrow Core):
   - escrow lifecycle & custody
   - roles and authority checks
   - events and queryable state
   - a minimal “dispute hook” state and resolver address reference

2) **ERC-ESCR-DISPUTE** (Dispute Resolution):
   - how disputes are opened
   - evidence submission schema
   - how rulings are produced (on-chain, optimistic, off-chain signed, etc.)
   - how rulings are enforced on the escrow contract (via a standardized `resolve` call)

### 5.2 Pros

- **Maximal adoptability**: escrow can be used without disputes, or with any dispute system.
- **Specialization**: dispute systems can innovate independently (juror courts, DAOs, ZK group consensus, optimistic disputes).
- **Wallet simplicity**: wallets can implement “escrow core” first and optionally support dispute modules.
- **Clear institutional boundaries**: escrow contracts don’t have to embed governance-heavy logic.

### 5.3 Cons

- **More moving pieces**: two interfaces to support.
- **More configuration**: which resolver applies to which escrow, and how it’s discovered.

### 5.4 Proposed authority boundary (important)

In the split model:

- The escrow contract is the **source of truth for custody and state**.
- The dispute resolver contract is the **source of truth for adjudication**.
- Enforcement is done by the escrow contract granting **limited authority** to the resolver:
  - Resolver can only call `resolve(escrowId, distribution)` when escrow is in `DISPUTED`.
  - Resolver cannot create escrows or bypass role constraints.

This maps cleanly to your current system (`authorizedResolver`, `resolverPartialRelease`, `resolverPartialCancel`) but upgrades it to be:
- Per-escrow configurable
- Interface-standardized
- Extensible to multiple resolver mechanisms

---

## 6) Option C: Fully modular composition (a “lego” set of escrow-related standards)

This is the “fully modular standard” approach: define a small core standard and a set of optional extension interfaces that can be composed.

### 6.1 Core: ERC-ESCR-CORE (must-have)

Responsibilities:
- Asset custody
- Unique escrow identifier
- Roles: payer/payee (and optionally “creator”)
- Settlement actions: release, cancel
- Timelocks (optional in core, but recommended)
- Canonical events

### 6.2 Extensions (optional interfaces)

Below is a recommended modular breakdown that directly matches your product direction (Everyday Wallet + group consensus + evidence + AA):

- **ERC-ESCR-ASSET** (multi-asset support)
  - Standardize “asset descriptor” (ERC20, native ETH, potentially ERC721/1155)
  - Standardize how escrow holds and releases each asset type

- **ERC-ESCR-FEES** (fee schedules)
  - Standardize fee basis points and fee recipient(s)
  - Support: flat fees, bps fees, and fee-on-settle vs fee-on-create

- **ERC-ESCR-TIMELOCKS** (timeouts)
  - `executeTimeout(escrowId)` that anyone can call when deadlines have passed
  - Optional “executor reward” (paid from fees or escrow amount) to incentivize bots/keepers

- **ERC-ESCR-EVIDENCE** (attachments/evidence)
  - `submitEvidence(escrowId, uri, contentHash, contentType, memo)`
  - Standardize max sizes and off-chain storage expectations (IPFS/Arweave/HTTPS)

- **ERC-ESCR-DISPUTE** (resolver integration)
  - `openDispute(escrowId, disputeMetadata)`
  - `resolve(escrowId, payouts[])` (resolver-only)
  - Standardize events for dispute lifecycle

- **ERC-ESCR-AUTH** (role delegation / group authorization)
  - Enables group consensus, multisig-like delegation, ZK proof-based approval
  - This is the natural place to align with `contracts/GroupEscrowExtension.sol`
  - Interface shape could be “authorizer contract” used by escrow for `canAct(role, action, escrowId, actor, proof)`

- **ERC-ESCR-PERMIT** (one-tx escrow creation)
  - ERC-2612 or Permit2 integration for ERC20 custody without separate approve
  - Important for AA and consumer UX

- **ERC-ESCR-INTENTS** (optional future-facing)
  - Standardize off-chain signed intents for creating or settling escrows (EIP-712)
  - Useful for relayers / AA, but should be optional

### 6.3 How wallets discover support (important)

To make this usable in practice, standardize discoverability:

- Escrow contracts should implement **ERC-165** (`supportsInterface`) to signal supported modules.
- Indexers can detect interface ids and adapt ingestion logic.
- Wallets can show/hide features based on extension support.

---

## 7) Proposed “next iteration” contract architecture for iWallet

### 7.1 Strategic shift: decouple token from escrow

Your current contract merges “token” and “escrow”. For a general escrow standard, and for long-term product flexibility, the next iteration should split:

- **EUSD token**: a standard ERC20 (no escrow logic).
- **Escrow contract(s)**: token-agnostic escrow vault(s) that can hold EUSD (and other assets).

Benefits:
- Supports escrowing any ERC20 (not just your own token)
- Makes standardization cleaner (escrow is not “a token standard”)
- Avoids coupling token upgrades with escrow upgrades
- Matches the app’s architecture: `ChainGateway` already abstracts contract calls

### 7.2 Core data model changes

Move from “array index as id” to an explicit id:

- **EscrowId**: `uint256` sequential id is fine, but define it as a first-class id in events and APIs.
- Optionally add **deterministic id**: `bytes32 escrowKey = keccak256(creator, payer, payee, asset, amount, salt)` for off-chain referencing.

### 7.3 Canonical roles and actions

Standardize roles in neutral terms:

- **payer**: deposits funds into escrow (often “buyer”)
- **payee**: receives funds if released (often “seller”)
- **resolver**: adjudicates disputes (optional)
- **creator**: may be payer or a third party (e.g., marketplace)

Standard actions:
- `release`: payer releases to payee (your current model)
- `requestCancel`: either party can request cancellation (optional)
- `confirmCancel`: counterparty confirms (two-step cancel)
- `openDispute`: either party
- `resolve`: resolver-only
- `submitEvidence`: either party
- `executeTimeout`: anyone (or authorized executors)

### 7.4 Event-first indexing: required for ecosystem adoption

Events must be designed so indexers can reconstruct state without bespoke calls:

Minimum events (recommended fields indexed):
- `EscrowCreated(uint256 indexed escrowId, address indexed payer, address indexed payee, address asset, uint256 amount, ...)`
- `EscrowStateChanged(uint256 indexed escrowId, uint8 oldState, uint8 newState)`
- `CancelRequested(uint256 indexed escrowId, address indexed by)`
- `DisputeOpened(uint256 indexed escrowId, address indexed by, address indexed resolver)`
- `EvidenceSubmitted(uint256 indexed escrowId, address indexed by, bytes32 contentHash, string uri)`
- `EscrowResolved(uint256 indexed escrowId, address indexed resolver, bytes32 resolutionHash)`

This directly fixes the current “workflowId parsing” fragility in the app.

### 7.5 Dispute model upgrade path (aligned to your code)

Your current resolver design is “authorizedResolver or owner” style. Evolve it to:

- **Per-escrow resolver**: chosen at creation time (or defaulted).
- **Resolver as contract**: implement a standard interface.
- **Resolution as distribution**: allow arbitrary splits rather than “partial release/cancel” only.

Recommended resolution primitive:
- `resolve(escrowId, payouts[])` where payouts are `(recipient, amount)` and must sum to escrow balance (minus fees, if fee-on-settle).

This generalizes:
- full release (100% to payee)
- full refund (100% to payer)
- partial splits
- multi-party payouts (marketplace commissions, affiliate fees, etc.)

### 7.6 Timelocks: standardize pull-based execution with incentives

Your `automateTimedActions` acknowledges the “Ethereum can’t wake itself” constraint.

In the next iteration:
- Store `releaseAfter` and/or `cancelAfter` timestamps on escrow.
- Provide `executeTimeout(escrowId)` callable by anyone.
- Optionally include an **executor reward** (fixed or bps) to incentivize keepers.

This enables reliable auto-settlement without a privileged server.

### 7.7 Evidence: keep on-chain minimal, store content off-chain

Storing unbounded arrays of strings is expensive and can become a griefing vector.

For standardization:
- Store only `bytes32 contentHash` + a `string uri` (or emit-only, depending on design).
- Consider an “event-only evidence” mode where evidence is never stored in contract storage, only emitted as events.

Everyday Wallet already uses signatures and hashes; this aligns well.

### 7.8 Group consensus and delegated authorization

`GroupEscrowExtension.sol` is effectively an authorization module that gates escrow actions on a “group approval proof”.

Standardize this as an **authorizer extension**:
- escrow core calls `authorizer.canAct(escrowId, action, actor, proof)` for sensitive actions
- allow swapping authorizers (none, multisig, ZK group consensus)

This keeps escrow core simple while enabling advanced social/collective workflows.

---

## 8) Proposed standard details (high-level specs)

This section defines an implementable direction (not final EIP text), with enough detail to guide your next contract iteration.

### 8.1 ERC-ESCR-CORE (Escrow Core) — suggested minimal interface

#### Data types (conceptual)

- `enum EscrowState { NONE, PENDING, RELEASED, REFUNDED, DISPUTED, RESOLVED }`
- `struct Asset { address token; uint8 assetType; uint256 amount; }`
  - `assetType`: `0=ERC20`, `1=NATIVE` (optional), `2=ERC721`, `3=ERC1155` (future)
- `struct Escrow { ... }`
  - `payer`, `payee`
  - `asset`
  - `state`
  - `createdAt`, `releaseAfter`, `cancelAfter`
  - `resolver` (optional)
  - `feeBps`, `feeRecipient` (optional; may be an extension)

#### Functions (conceptual)

- `createEscrow(payer, payee, asset, terms) returns (uint256 escrowId)`
- `getEscrow(escrowId) view returns (Escrow)`
- `release(escrowId)` (payer-authorized, or delegated via auth module)
- `requestCancel(escrowId)` (payer/payee authorized)
- `confirmCancel(escrowId)` (counterparty authorized)
- `openDispute(escrowId, disputeMetadata)` (payer/payee authorized; transitions to DISPUTED)
- `executeTimeout(escrowId)` (anyone; transitions based on deadlines)

#### Events (required)

- `EscrowCreated(...)` (with indexed id and parties)
- `EscrowStateChanged(...)`

Other events (recommended):
- `CancelRequested(...)`
- `CancelConfirmed(...)`
- `DisputeOpened(...)`
- `TimeoutExecuted(...)`

### 8.2 ERC-ESCR-DISPUTE (Dispute Resolution) — suggested interface

#### Resolver interface

- `onDisputeOpened(escrow, disputeMetadata)` (optional callback)
- `resolve(escrowId, payouts[], resolutionMetadata)` (calls escrow core `resolve`)

#### Resolution enforcement on escrow core

Escrow core exposes:
- `resolve(escrowId, payouts[], resolutionHash)` callable only by the configured resolver (or a resolver registry).

This matches your current “authorized resolver overrides” but standardizes it.

### 8.3 ERC-ESCR-EVIDENCE (Evidence) — suggested interface

- `submitEvidence(escrowId, uri, contentHash, contentType, memo)`
- `EvidenceSubmitted(escrowId, submitter, contentHash, uri, ...)`

### 8.4 ERC-ESCR-AUTH (Authorization) — suggested interface

Core idea:
- Escrow core defers authorization checks to a plug-in contract for specific actions.

Possible interface:
- `canAct(escrowId, action, actor, role, proofData) view returns (bool)`

This is where:
- multisig approvals// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

// Uncomment this line to use console.log
// import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "hardhat/console.sol";

// Custom errors for better user experience
error InsufficientTokenBalance(uint256 balance, uint256 required);
error InvalidWorkflowId(uint256 workflowId);
error TransferNotPending(uint256 workflowId);
error NotAuthorizedResolver(address caller);

enum EscrowTransferStatus {
    PENDING,
    RELEASED,
    CANCELLED,
    DISPUTE,
    RESOLVER_OVERRIDDEN
}

enum SenderStatus {
    NONE,
    AGREE_TO_CANCEL,
    RAISE_DISPUTE
}

enum RecipientStatus {
    NONE,
    AGREE_TO_CANCEL,
    RAISE_DISPUTE
}

struct EscrowTransfer {
    uint256 workflowId;
    address to;
    address from;
    uint amount; // amount held in escrow
    uint originalAmount; // original amount of the transfer
    EscrowTransferStatus escrowTransferStatus;
    SenderStatus senderStatus;
    RecipientStatus recipientStatus;
    string[] attachmentURIs;
    bytes32[] attachmentHashes;
    address disputeResolver;
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
}

contract EscrowableERC20 is Context, ERC20, Ownable, ReentrancyGuard {

    uint256 public constant ESCROW_FEE = 100;
    uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;
    uint256 public nextWorkflowId = 0;
    EscrowTransfer[] public escrowTransfers;
    address public escrowFeeAddress;
    uint256 public totalFees = 0;
    address public authorizedResolver;
    uint256 public defaultAutoReleaseTime = 0; // 0 means no auto release
    uint256 public defaultAutoCancelTime = 0; // 0 means no auto cancel 
    uint256 public maxAttachments = 10;

    event EscrowTransferCreated(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferReleased(uint256 indexed workflowId, address indexed to, uint256 amount);
    event EscrowTransferCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);
    event EscrowTransferDisputed(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolved(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolvedWithPartialRelease(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferResolvedWithPartialCancel(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferAutoReleased(uint256 indexed workflowId, address indexed to, uint256 amount);
    event EscrowTransferAutoCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);

    event EvidenceSubmitted(uint256 indexed workflowId, address indexed from, address indexed to, string evidence);

    

    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(_msgSender()) {
        // owner = _msgSender();
        escrowFeeAddress = _msgSender();
        authorizedResolver = _msgSender();
        _mint(_msgSender(), 1000000000000000000000000);
        address se1 = address(0x904Bc1F3C62c902052dF2DD69513c600421c2b72);
        _mint(se1, 10000000000000000000);
        address testSender = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        _mint(testSender, 1000000000000000000000000);
        address testRecipient1 = address(0xfbC02DB7Fd2CF08Fa7F39D7e573b8d8f6B28585F);
        _mint(testRecipient1, 1000000000000000000000000);
    }

    function setDefaultAutoCancelTime(uint256 time) public onlyOwner {
        defaultAutoCancelTime = time;
    }

    function setDefaultAutoReleaseTime(uint256 time) public onlyOwner {
        defaultAutoReleaseTime = time;
    }

    function timedEscrowTransfer(address to, uint256 amount, uint256 autoReleaseTime, uint256 autoCancelTime) public returns (uint256) {
        require(autoReleaseTime == 0 || autoCancelTime == 0, "Cannot set both auto release and auto cancel");
        escrowTransfer(to, amount);
        escrowTransfers[nextWorkflowId - 1].autoReleaseTime = autoReleaseTime;
        escrowTransfers[nextWorkflowId - 1].autoCancelTime = autoCancelTime;
        emit EscrowTransferCreated(nextWorkflowId - 1, to, _msgSender(), amount);
        return nextWorkflowId - 1;
    }

    /** As Ethereum can't trigger a timed action itself, this function needs to be called periodically.
        Called by a server. Could add a small reward to incentivise timely actions and create resilience to the server being down
     */
    function automateTimedActions(uint256 workflowId) public returns (bool) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        if(et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime) {
            releaseEscrowTransfer(workflowId);
            emit EscrowTransferAutoReleased(workflowId, et.to, et.amount);
        }
        if(et.autoCancelTime > 0 && block.timestamp >= et.autoCancelTime) {
            cancelAndRefund(workflowId);
            emit EscrowTransferAutoCancelled(workflowId, et.from, et.amount);
        }
        return true;
    }

    /** Defining a range is necessary to avoid hitting gas limitations with a large number of workflows */
    function automateTimedActions(uint256 workflowIdRangeStart, uint256 workflowIdRangeEnd) public returns (bool) {
        for(uint256 i = workflowIdRangeStart; i < workflowIdRangeEnd; i++) {
            automateTimedActions(i);
        }
        return true;
    }

    function automateTimedActions() public returns (bool) {
        automateTimedActions(0, nextWorkflowId - 1);
        return true;
    }

    function escrowTransfer(address to, uint256 amount) public returns (uint256) {
        uint256 fee = amount * ESCROW_FEE / ESCROW_FEE_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;
        escrowTransfers.push(EscrowTransfer(
            {
                workflowId: nextWorkflowId,
                to: to, 
                from: _msgSender(), 
                amount: amountAfterFee,
                originalAmount: amount,
                escrowTransferStatus: EscrowTransferStatus.PENDING,
                senderStatus: SenderStatus.NONE,
                recipientStatus: RecipientStatus.NONE,
                attachmentURIs: new string[](0),
                attachmentHashes: new bytes32[](0), 
                disputeResolver: authorizedResolver,
                autoReleaseTime: defaultAutoReleaseTime,
                autoCancelTime: defaultAutoCancelTime
            }));
        assert(escrowTransfers[nextWorkflowId].amount == amountAfterFee);
        assert(escrowTransfers[nextWorkflowId].to == to);
        assert(escrowTransfers[nextWorkflowId].from == _msgSender());

        // Check if sender has sufficient balance
        if (balanceOf(_msgSender()) < amount) {
            revert InsufficientTokenBalance({
                balance: balanceOf(_msgSender()),
                required: amount
            });
        }

        transfer(address(this), amount);
        totalFees += fee;
        nextWorkflowId++;
        emit EscrowTransferCreated(nextWorkflowId - 1, to, _msgSender(), amount);
        return nextWorkflowId - 1;
    }

    function addAttachment(uint workflowId, string memory uri, bytes32 hash) public returns (bool) {
        require(escrowTransfers[workflowId].attachmentURIs.length < maxAttachments, "Maximum number of attachments reached");
        if (workflowId >= nextWorkflowId) {
            revert InvalidWorkflowId(workflowId);
        }
        escrowTransfers[workflowId].attachmentURIs.push(uri);
        escrowTransfers[workflowId].attachmentHashes.push(hash);
        return true;
    }

    function addAttachmentSet(uint workflowId, string[] memory uris, bytes32[] memory hashes) public returns (bool) {
        require(escrowTransfers[workflowId].attachmentURIs.length + uris.length <= maxAttachments, "Maximum number of attachments reached");
        if (workflowId >= nextWorkflowId) {
            revert InvalidWorkflowId(workflowId);
        }
        for(uint i = 0; i < uris.length; i++) {
            escrowTransfers[workflowId].attachmentURIs.push(uris[i]);
            escrowTransfers[workflowId].attachmentHashes.push(hashes[i]);
        }
        return true;
    }

    function releaseEscrowTransferWithAttachment(uint256 workflowId, string memory uri, bytes32 hash) public returns (bool) {
        addAttachment(workflowId, uri, hash);
        releaseEscrowTransfer(workflowId);
        return true;
    }

    function releaseEscrowTransferWithAttachmentSet(uint256 workflowId, string[] memory uris, bytes32[] memory hashes) public returns (bool) {
        addAttachmentSet(workflowId, uris, hashes);
        releaseEscrowTransfer(workflowId);
        return true;
    }

    function releaseEscrowTransfer(uint256 workflowId) public returns (bool) {
        if (workflowId >= nextWorkflowId) {
            revert InvalidWorkflowId(workflowId);
        }
        
        EscrowTransfer storage et = escrowTransfers[workflowId];

        if (et.escrowTransferStatus != EscrowTransferStatus.PENDING) {
            revert TransferNotPending(workflowId);
        }
        
        if (et.from != _msgSender()) {
            revert("You are not the sender");
        }
        
        et.escrowTransferStatus = EscrowTransferStatus.RELEASED; 
        uint256 amount = et.amount;
        address to = et.to;
        et.amount = 0;
        _transfer(address(this), to, amount);
        emit EscrowTransferReleased(workflowId, to, et.originalAmount);
        return true;
    }

    function cancelAndRefund(uint256 workflowId) internal returns (bool) {
        escrowTransfers[workflowId].escrowTransferStatus = EscrowTransferStatus.CANCELLED;
        _transfer(address(this),escrowTransfers[workflowId].from, escrowTransfers[workflowId].amount);
        escrowTransfers[workflowId].amount = 0;
        emit EscrowTransferCancelled(workflowId, escrowTransfers[workflowId].from, escrowTransfers[workflowId].originalAmount);
        return true;
    }

    function recipientCancel(uint256 workflowId) public returns (bool) {
        require(workflowId < nextWorkflowId, "Workflow ID is out of bounds");
        EscrowTransfer storage et = escrowTransfers[workflowId];
        require(et.to == _msgSender(), "You are not the recipient");
        if(et.escrowTransferStatus == EscrowTransferStatus.CANCELLED) {
            revert("Transfer is already cancelled");
        }
        if(et.escrowTransferStatus == EscrowTransferStatus.DISPUTE) {
            revert("Transfer is in dispute");
        }
        if(et.escrowTransferStatus == EscrowTransferStatus.RELEASED) {
            revert("Transfer is already released");
        }
        if(et.escrowTransferStatus == EscrowTransferStatus.RESOLVER_OVERRIDDEN) {
            revert("Transfer is already resolved");
        }
        require(et.escrowTransferStatus == EscrowTransferStatus.PENDING, "Transfer is not pending");
        et.recipientStatus = RecipientStatus.AGREE_TO_CANCEL;

        if (et.senderStatus == SenderStatus.AGREE_TO_CANCEL) {
            cancelAndRefund(workflowId);
        }
        return true;
    }

    function senderCancel(uint256 workflowId) public returns (bool) {
        require(workflowId < nextWorkflowId, "Workflow ID is out of bounds");
        EscrowTransfer storage et = escrowTransfers[workflowId];
        require(et.from == _msgSender(), "You are not the sender");
        require(et.escrowTransferStatus == EscrowTransferStatus.PENDING, "Transfer is not pending");
        
        et.senderStatus = SenderStatus.AGREE_TO_CANCEL;
        
        if (et.recipientStatus == RecipientStatus.AGREE_TO_CANCEL) {
            cancelAndRefund(workflowId);
        }
        return true;
    }

    function setAuthorizedResolver(address resolver) public onlyOwner {
        authorizedResolver = resolver;
    }

    function resolverCancel(uint256 workflowId) public returns (bool) {
        if (!_isAuthorizedResolver(_msgSender())) {
            revert NotAuthorizedResolver(_msgSender());
        }
        EscrowTransfer storage et = escrowTransfers[workflowId];
        require(et.escrowTransferStatus == EscrowTransferStatus.DISPUTE, "Transfer is not in dispute");
        uint256 originalAmount = et.amount;
        cancelAndRefund(workflowId);
        et.escrowTransferStatus = EscrowTransferStatus.RESOLVER_OVERRIDDEN;
        emit EscrowTransferResolved(workflowId, et.from, et.to, originalAmount);
        return true;
    }

    function resolverRelease(uint256 workflowId) public returns (bool) {
        if (!_isAuthorizedResolver(_msgSender())) {
            revert NotAuthorizedResolver(_msgSender());
        }
        EscrowTransfer storage et = escrowTransfers[workflowId];
        require(et.escrowTransferStatus == EscrowTransferStatus.DISPUTE, "Transfer is not in dispute");
        uint256 originalAmount = et.amount;
        uint256 amount = et.amount;
        address to = et.to;
        et.amount = 0;
        _transfer(address(this), to, amount);
        et.escrowTransferStatus = EscrowTransferStatus.RESOLVER_OVERRIDDEN;
        emit EscrowTransferResolved(workflowId, et.from, to, originalAmount);
        return true;
    }

    function resolverPartialRelease(uint256 workflowId, uint256 amount) public returns (bool) {
        if (!_isAuthorizedResolver(_msgSender())) {
            revert NotAuthorizedResolver(_msgSender());
        }
        EscrowTransfer storage et = escrowTransfers[workflowId];
        require(et.escrowTransferStatus == EscrowTransferStatus.DISPUTE, "Transfer is not in dispute");

        require(amount <= et.amount, "Amount is greater than the transfer amount");
        address releaseTo = et.to;
        et.amount -= amount;
        _transfer(address(this), releaseTo, amount);
        emit EscrowTransferResolvedWithPartialRelease(workflowId, et.from, releaseTo, amount);
        if (et.amount == 0) {
            et.escrowTransferStatus = EscrowTransferStatus.RESOLVER_OVERRIDDEN;
            emit EscrowTransferResolved(workflowId, et.from, releaseTo, et.originalAmount);
        }
        return true;
    }

    function resolverPartialCancel(uint256 workflowId, uint256 amount) public returns (bool) {
        if (!_isAuthorizedResolver(_msgSender())) {
            revert NotAuthorizedResolver(_msgSender());
        }
        EscrowTransfer storage et = escrowTransfers[workflowId];
        require(et.escrowTransferStatus == EscrowTransferStatus.DISPUTE, "Transfer is not in dispute");

        require(amount <= et.amount, "Amount is greater than the transfer amount");
        address refundTo = et.from;
        et.amount -= amount;
        _transfer(address(this), refundTo, amount);
        emit EscrowTransferResolvedWithPartialCancel(workflowId, refundTo, et.to, amount);
        if (et.amount == 0) {
            et.escrowTransferStatus = EscrowTransferStatus.RESOLVER_OVERRIDDEN;
            emit EscrowTransferResolved(workflowId, refundTo, et.to, et.originalAmount);
        }
        return true;
    }

    /**
     * @dev Check if an address is an authorized resolver
     * @param resolver Address to check
     * @return True if authorized, false otherwise
     */
    function _isAuthorizedResolver(address resolver) internal view returns (bool) {
        // Check if it's the legacy authorized resolver
        if (resolver == authorizedResolver) {
            return true;
        }
        return false;
    }

    function raiseDispute(uint256 workflowId) public returns (bool) {
        if(escrowTransfers[workflowId].from == _msgSender()) {
            escrowTransfers[workflowId].senderStatus = SenderStatus.RAISE_DISPUTE;
            escrowTransfers[workflowId].escrowTransferStatus = EscrowTransferStatus.DISPUTE;
        } else if(escrowTransfers[workflowId].to == _msgSender()) {
            escrowTransfers[workflowId].recipientStatus = RecipientStatus.RAISE_DISPUTE;
            escrowTransfers[workflowId].escrowTransferStatus = EscrowTransferStatus.DISPUTE;
        } else {
            revert("You are not a participant in this transfer");
        }
        emit EscrowTransferDisputed(workflowId, escrowTransfers[workflowId].from, escrowTransfers[workflowId].to, escrowTransfers[workflowId].amount);
        return true;
    }

    function withdrawFees() public returns (bool) {
        require(_msgSender() == escrowFeeAddress, "You are not the fee address");
        _transfer(address(this), _msgSender(), totalFees);
        totalFees = 0;
        return true;
    }

    // Getter functions for attachments
    function getAttachmentURIs(uint256 workflowId) public view returns (string[] memory) {
        if (workflowId >= nextWorkflowId) {
            revert InvalidWorkflowId(workflowId);
        }
        return escrowTransfers[workflowId].attachmentURIs;
    }

    function getAttachmentHashes(uint256 workflowId) public view returns (bytes32[] memory) {
        if (workflowId >= nextWorkflowId) {
            revert InvalidWorkflowId(workflowId);
        }
        return escrowTransfers[workflowId].attachmentHashes;
    }
}

contract EscrowableERC20Factory {
    function createEscrowableERC20(string memory name, string memory symbol) public returns (address) {
        return address(new EscrowableERC20(name, symbol));
    }
}

- group ZK proofs
- delegated roles (marketplace acting on behalf of user)
can be standardized without bloating escrow core.

---

## 9) Design considerations & pitfalls (lessons from the current contract)

### 9.1 State machine safety

The current `raiseDispute` does not prevent transitioning a non-pending escrow into dispute. A standard should require:
- Only `PENDING` can become `DISPUTED`
- Only `DISPUTED` can be resolved by resolver
- Terminal states must be terminal

### 9.2 Reentrancy and token quirks

Escrow contracts must be hardened for:
- ERC20 tokens that return `false` vs revert
- fee-on-transfer tokens (received amount < sent amount)
- callbacks (ERC777), malicious tokens, and reentrancy through external calls

Standard should recommend:
- `SafeERC20` usage
- checks-effects-interactions pattern
- optionally restricting assets to “well-behaved ERC20s” (policy choice)

### 9.3 Storage griefing

On-chain arrays of strings (`attachmentURIs`) can be griefed.

Prefer:
- event-only evidence
- or capped evidence slots with hash-only storage

### 9.4 Indexing and upgrade resilience

For adoption, events must be:
- stable
- indexed correctly
- sufficient to reconstruct escrow state transitions

Avoid requiring indexers to read entire escrow structs for every change.

### 9.5 Account abstraction friendliness

For consumer UX, avoid “approve then create escrow” where possible.

Standardize an optional extension:
- `createEscrowWithPermit(...)`
- Or Permit2 support

This is particularly important for AA flows where signatures and bundling are common.

---

## 10) Practical recommendations for iWallet’s next iteration

### Recommendation 1: implement escrow as a standalone vault contract

Deliver:
- `EscrowVault` (ERC-ESCR-CORE + selected extensions)
- Keep `EUSD` as a separate ERC20 token

Update the wallet:
- Swap the ABI + contract address in configuration (the `ChainGateway` is already designed for this)
- Keep the higher-level `useEscrow` and `EscrowActionService` APIs stable

### Recommendation 2: standardize your event schema first (even before full modularization)

Immediate, high leverage:
- Introduce a consistent set of **indexed events** and emit them on every transition.
- Ensure `escrowId` is in an indexed topic.

This will unlock:
- reliable workflow id extraction
- better escrow lists (without heavy `getEscrowTransfer` polling)
- easier integration with third-party explorers and indexers

### Recommendation 3: treat dispute resolution as a plug-in contract

Ship:
- A default `EverydayResolver` (could remain “authorized resolver” initially)
- A path to integrate third-party arbitration later

### Recommendation 4: make timeouts permissionless + incentivized

Ship:
- `executeTimeout(escrowId)` callable by anyone
- Optional executor reward to ensure real-world reliability

### Recommendation 5: align group consensus as an authorization extension

Refactor `GroupEscrowExtension` direction into a standard “authorizer” interface.
This can become a powerful differentiator: collective escrows, shared custody, and social enforcement.

---

## 11) Suggested rollout plan

1) **Stabilize the schema**
   - Define core events, state enum, and function names.

2) **Build EscrowVault v2**
   - ERC20 custody + release/cancel/dispute hooks
   - event-first indexing

3) **Integrate in Everyday Wallet**
   - Update ChainGateway ABI and method mappings
   - Keep `useEscrow` API stable

4) **Add Dispute Resolver interface**
   - Migrate existing “authorized resolver” logic behind the standard

5) **Add optional modules**
   - Evidence module
   - Timelocks module
   - Authorization module (group consensus)
   - Permit module (one-tx creation)

---

## 12) Open questions to resolve before finalizing the EIP(s)

To finalize the standard text and the next contract iteration, these decisions matter:

- **Asset scope**: ERC20-only at first, or include native ETH as well?
- **Fee policy**: fee-on-create vs fee-on-settle; who pays?
- **Evidence policy**: store evidence on-chain vs event-only; max evidence entries?
- **Dispute policy**: optimistic disputes vs adjudicated; what is the minimum standard hook?
- **Resolver discovery**: per-escrow resolver vs registry; should the registry be standardized?
- **Role delegation**: should creators (marketplaces) be first-class roles?
- **Privacy**: do we need private escrows (ZK)? If so, escrow id and evidence semantics change.

