2026 Solidity withdrawal best practices


Best practices for Ethereum smart-contract withdrawals — May 2026
1. Default pattern: pull withdrawals, not auto-push transfers
Use pull-based withdrawals wherever possible.
That means the contract records that a user is entitled to funds, and the user or their authorised wallet later calls withdraw(...) to receive them. This remains the dominant security best practice because it avoids automatically calling arbitrary recipient contracts and reduces denial-of-service and reentrancy risk. Ethereum.org’s current smart-contract security docs explicitly recommend pull payments to avoid triggering unknown code and to prevent some denial-of-service attacks; OpenZeppelin’s PullPayment documentation similarly describes pull payments as a security best practice. 
Coding-agent rule
Prefer:
  credit[user] += amount
  user calls withdraw(amount, recipient)
Avoid:
  protocol loops over users and sends funds automatically
  protocol pushes funds during unrelated state transitions
  protocol sends to arbitrary recipients before state is finalized
2. Use Checks-Effects-Interactions everywhere
Withdrawal functions should follow:
1. Checks
   - caller is authorised
   - withdrawal is currently allowed
   - amount > 0
   - amount <= withdrawable balance
   - recipient is valid
   - escrow/dispute/yield state permits withdrawal
2. Effects
   - decrement user balance
   - mark escrow state as withdrawn/released/cancelled
   - update accounting totals
   - emit intent/accounting event if useful
3. Interactions
   - perform token or ETH transfer last
The Solidity security documentation still recommends the Checks-Effects-Interactions pattern and specifically says a withdraw pattern is preferable to a send pattern when recipient execution could block progress. 
Coding-agent rule
function withdraw(uint256 amount, address recipient)
    external
    nonReentrant
{
    // CHECKS
    if (recipient == address(0)) revert InvalidRecipient();
    uint256 bal = withdrawable[msg.sender];
    if (amount == 0 || amount > bal) revert InvalidAmount();
    // EFFECTS
    withdrawable[msg.sender] = bal - amount;
    totalWithdrawable -= amount;
    emit WithdrawalClaimed(msg.sender, recipient, amount);
    // INTERACTIONS
    _safeTransferOut(asset, recipient, amount);
}
3. Use nonReentrant, but do not rely on it alone
Use ReentrancyGuard or an equivalent guard on all withdrawal, release, refund, cancel, yield-unwind, and bond-withdrawal paths.
But treat it as a belt, not the core safety mechanism. The core safety should come from:
- state updates before external calls
- idempotent accounting
- one-way state transitions
- per-claim accounting
- no external callbacks during incomplete state
Reentrancy remains a live class of Ethereum vulnerability; current security guidance continues to recommend ReentrancyGuard plus Checks-Effects-Interactions rather than relying on gas-stipend assumptions. 
4. Avoid transfer() and send() for ETH
For native ETH withdrawals, use low-level call{value: amount}("") and check the result. Do not use transfer() or send() as a modern safety primitive.
The old idea was that the 2,300 gas stipend limited reentrancy. That assumption has aged badly because gas costs can change, and contract-wallet recipients often need more than 2,300 gas. ConsenSys Diligence has long recommended avoiding transfer() and send() for this reason. 
Coding-agent rule
(bool ok, ) = recipient.call{value: amount}("");
if (!ok) revert EthTransferFailed();
Then combine this with:
- nonReentrant
- CEI
- pull-based design
- failure isolation
5. Token withdrawals: use safe transfer libraries
For ERC-20 withdrawals, use SafeERC20.safeTransfer and safeTransferFrom.
Do not assume:
- token returns true
- token has no fee-on-transfer behavior
- token cannot reenter through ERC-777-style hooks or malicious token logic
- token decimals are standard
- token balance changes exactly equal requested amount
Coding-agent rule
using SafeERC20 for IERC20;
function _safeTransferOut(address asset, address recipient, uint256 amount) internal {
    if (asset == address(0)) {
        (bool ok, ) = recipient.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    } else {
        IERC20(asset).safeTransfer(recipient, amount);
    }
}
For protocols supporting arbitrary ERC-20s, add explicit allowlisting or per-token adapters. Arbitrary-token support increases integration risk.
6. Separate “entitlement” from “delivery”
A robust withdrawal system should distinguish:
Entitlement:
  The protocol has determined that address X may claim amount Y.
Delivery:
  X or an authorised delegate actually calls withdraw and receives funds.
This is important for both security and regulatory simplicity.
Preferred states
NONE
DEPOSITED
RELEASABLE
CLAIMABLE
WITHDRAWN
CANCELLED
DISPUTED
RESOLVED_BUYER
RESOLVED_SELLER
EXPIRED
Preferred accounting
claimable[asset][user] -> amount
escrowClaimed[escrowId] -> bool
withdrawalNonce[user] -> uint256
totalClaimable[asset] -> amount
Key invariant
sum(claimable[asset][all users]) <= contractBalance(asset)
For a single escrow:
escrow cannot be withdrawn twice
escrow cannot be both refunded and released
escrow cannot release funds while disputed unless resolution permits it
escrow cannot be modified by governance after creation if rules are snapshot/frozen
7. Design withdrawal functions as user actions
For regulatory simplicity, the cleanest design is:
User initiates:
  withdraw
  refund claim
  release claim
  bond withdrawal
  yield withdrawal
  beneficiary claim
  rescue claim
Protocol may compute:
  eligibility
  entitlement
  expiry
  state transition
  claimable amount
Protocol should avoid:
  automatically pushing funds to users without a user call
  sweeping user balances into new strategies
  selecting destination addresses on behalf of users
  batching payments as an operator-controlled money movement service
This does not magically remove regulatory risk, but it keeps the smart contract closer to a neutral, non-custodial rules engine. In the EU, MiCA separately defines “providing transfer services for crypto-assets on behalf of clients” as transferring crypto-assets from one DLT address/account to another on behalf of a person, and ESMA’s MiCA transfer-service guidelines focus on client transfer instructions, information, rejection/suspension, and execution obligations for CASPs. 
8. Regulatory-simplicity guidance: user-driven vs automated
This is not legal advice, but as an engineering heuristic:
Action
Prefer
Avoid
Why
User withdraws own claimable funds
User calls withdraw
Operator auto-pushes to user
Cleaner non-custodial/user-initiated posture
Recipient selection
User supplies recipient or pre-authorised recipient
Protocol/operator chooses recipient
Avoid appearing to control transfer destination
Refund after timeout
User calls claimRefund
Bot automatically sends refund
Keeps delivery user-driven
Release after buyer approval
Seller calls claimRelease or buyer explicitly releases
Protocol auto-sends at approval moment
Separates entitlement from transfer execution
Dispute resolution payout
Resolution makes funds claimable
Resolver/operator directly sends funds
Resolver decides outcome, not custody/delivery
Yield withdrawal
User opts in and later claims
Protocol periodically pushes yield
Avoid automated distribution/payment-service optics
Emergency unwind
Protocol unwinds to escrow/accounting layer
Protocol sends directly to arbitrary users
Keep safety action distinct from user delivery
Dust recovery
User-claimable or governance-limited rescue after delay
Admin sweeps user balances
Avoid seizure/custody concerns
The key distinction is:
Good:
  protocol determines rights under pre-committed rules
Riskier:
  protocol/operator actively moves user funds to chosen destinations
9. When automation is acceptable
Some automation is usually fine if it is mechanical, rule-bound, and does not choose recipients or redirect value.
Acceptable automation:
- marking an escrow expired
- marking funds claimable after timeout
- calculating yield
- updating accounting indexes
- unwinding from an approved yield module back into escrow custody
- pausing new withdrawals during a narrowly scoped emergency if non-custodial exits remain protected
- processing a user-signed withdrawal intent submitted by a relayer
Higher-risk automation:
- protocol-initiated recurring payouts
- operator-triggered transfers to user addresses
- admin-selected recipient changes
- auto-routing through offchain compliance or custody providers
- auto-conversion, swap, bridge, or yield migration without explicit user instruction
The EU Transfer of Funds Regulation and EBA travel-rule guidelines apply to CASPs and related crypto-asset transfers from 30 December 2024; where a regulated CASP is involved, policies must determine information requirements and whether exclusions/derogations apply. That is one reason protocol-level automation should be kept distinct from regulated frontend/operator services. 
10. Relayers and gas sponsorship
A relayer can submit a withdrawal transaction, but the withdrawal should still be user-authorised.
Preferred:
- user signs EIP-712 withdrawal intent
- signed intent includes:
  - chainId
  - contract address
  - asset
  - amount
  - recipient
  - nonce
  - deadline
- relayer submits transaction
- contract verifies signature
- funds go only to the signed recipient
Avoid:
- relayer chooses recipient
- relayer can change amount
- relayer can aggregate claims without explicit user signatures
- signatures are reusable across chains/contracts
Coding-agent requirements
Implement:
  withdrawWithSig(owner, recipient, asset, amount, nonce, deadline, signature)
Check:
  block.timestamp <= deadline
  nonce unused
  recovered signer == owner
  recipient == signed recipient
  asset == signed asset
  amount == signed amount
  domain separator includes chainId and contract address
11. Batch withdrawals
Batch withdrawals are useful but dangerous.
Use batching only when:
- every withdrawal is independently authorised
- one failed recipient cannot block the entire batch
- batch caller cannot redirect funds
- batch emits per-withdrawal events
- gas limits are bounded
Avoid:
for each user:
    transfer(user, amount)
Better:
for each signed withdrawal intent:
    validate signature
    decrement claimable
    transfer to signed recipient
    if failure, revert only that item or skip with explicit event
But for maximum simplicity, prefer one claim per transaction unless UX strongly requires batching.
12. Withdrawal destination rules
Recommended default:
recipient == msg.sender
Optional advanced mode:
recipient can differ if:
  - user explicitly supplies it in calldata, or
  - user signs it in EIP-712 message, or
  - recipient was pre-registered by the user with a delay
Avoid allowing:
- resolver-selected recipients
- admin-selected recipients
- frontend-injected recipients without clear signing
- mutable default withdrawal address controlled by operator
13. Time locks, expiry, and cancellation
For escrow-like protocols:
- release path should be explicit
- refund path should be explicit
- timeout path should make funds claimable, not automatically pushed
- disputed funds should be locked until resolution
- post-resolution funds should become claimable by the winning party
Recommended withdrawal gates
canWithdrawSeller(escrowId):
  state == RELEASED || state == RESOLVED_SELLER
  not withdrawn
canWithdrawBuyer(escrowId):
  state == CANCELLED || state == EXPIRED || state == RESOLVED_BUYER
  not withdrawn
canWithdrawResolverBond(resolver):
  no pending slash exposure
  no unresolved assigned cases
  exit delay elapsed
14. Resolver/staker bond withdrawals
For dispute systems, bond withdrawal must be stricter than user fund withdrawal.
Required controls:
- withdrawal delay / unbonding period
- cannot withdraw if assigned to unresolved dispute
- cannot withdraw if slash is pending
- cannot withdraw below minimum active stake
- slash claims have priority over bond exit
- epoch snapshot prevents withdrawing after malicious verdict but before slash
Critical invariant
resolver slashable stake at verdict time remains slashable until:
  dispute finality window expires, or
  all appeals/slash paths are complete
Coding-agent test cases
- resolver attempts bond withdrawal immediately after corrupt verdict
- resolver withdraws before appeal submitted
- resolver withdraws during appeal window
- resolver withdraws after slash initiated but before slash executed
- resolver withdraws below active minimum then accepts case
- resolver exits one address and re-enters via another to avoid penalty
15. Emergency pause and withdrawal safety
Pause should not be a blanket “freeze all user funds” unless absolutely necessary.
Preferred pause semantics:
Pause disables:
  - new escrow creation
  - new yield deposits
  - new dispute initiation if risk requires
  - risky module calls
Pause does not disable:
  - user withdrawal of already-claimable funds
  - cancellation where both parties agree
  - emergency unwind from yield module back to escrow custody
  - resolution finalization if already safely determined
For Sew-style design, this matches the goal: governance can reduce new risk without gaining custody-like power over active funds.
16. Yield-module withdrawals
If funds are deployed into Aave or another yield module, withdrawal design should preserve custody boundaries.
Preferred model:
Escrow contract owns accounting.
Yield module can only:
  - receive from escrow
  - return to escrow
  - report balances
  - emergencyUnwind back to escrow
Yield module cannot:
  - send directly to users
  - redirect funds to governance
  - change escrow beneficiaries
  - retain funds after unwind
User-flow
1. User/seller/buyer becomes entitled.
2. Protocol unwinds yield if needed.
3. Escrow marks amount claimable.
4. User calls withdraw.
Do not combine yield unwind and arbitrary user transfer unless strictly necessary.
17. Events and observability
Emit events for every entitlement and every delivery.
Recommended events:
event ClaimableCreated(
    bytes32 indexed claimId,
    address indexed asset,
    address indexed claimant,
    uint256 amount,
    bytes32 reason
);
event WithdrawalClaimed(
    bytes32 indexed claimId,
    address indexed asset,
    address indexed claimant,
    address recipient,
    uint256 amount
);
event WithdrawalFailed(
    bytes32 indexed claimId,
    address indexed asset,
    address indexed claimant,
    address recipient,
    uint256 amount,
    bytes reason
);
For regulatory simplicity and auditability, events should make clear whether the protocol merely created an entitlement or actually delivered funds.
18. Failure handling
For single withdrawals:
- revert on transfer failure
- restore state automatically via revert
For batch withdrawals:
Option A: all-or-nothing batch
  simpler accounting, worse UX
Option B: per-item isolation
  more complex, better failure isolation
  must emit success/failure per item
Avoid silent failures.
19. Do not let governance redirect withdrawals
Governance should be unable to:
- change recipient of active escrow
- seize claimable balances
- rewrite withdrawal eligibility for active escrows
- replace withdrawal module for already-created escrows unless explicitly snapshotted and pre-authorised
- sweep “inactive” balances without a long, objective, user-protective process
Governance may:
- change parameters for future escrows
- pause new risk
- upgrade modules for new escrows
- trigger emergency unwind back to escrow custody
20. Coding-agent checklist
Withdrawal implementation checklist:
[ ] Use pull withdrawal by default.
[ ] Never auto-push funds during unrelated transitions.
[ ] Separate entitlement creation from fund delivery.
[ ] Apply Checks-Effects-Interactions.
[ ] Add nonReentrant to withdrawal-like functions.
[ ] Use SafeERC20 for ERC-20 transfers.
[ ] Use call{value: amount} for ETH and check success.
[ ] Do not use transfer() or send().
[ ] Validate recipient.
[ ] Prefer recipient == msg.sender unless explicit signed authorisation exists.
[ ] Include chainId, contract, recipient, amount, asset, nonce, and deadline in signatures.
[ ] Prevent replay.
[ ] Emit entitlement and withdrawal events.
[ ] Ensure failed transfer cannot corrupt accounting.
[ ] Ensure one failed recipient cannot block unrelated withdrawals.
[ ] Add bond unbonding windows for resolvers.
[ ] Prevent bond withdrawal while slash exposure exists.
[ ] Do not allow governance/admin to redirect active funds.
[ ] Pause should not unnecessarily block already-claimable withdrawals.
[ ] Add invariant tests for conservation of funds.
[ ] Add fuzz tests for reentrancy, malicious tokens, failing recipients, and repeated claims.
21. Minimal coding-agent spec
Implement a withdrawal subsystem with the following architecture:
1. Entitlements
   - Maintain claimable[asset][claimant].
   - Entitlements are created only by validated protocol state transitions.
   - Entitlement creation must not transfer funds.
2. Withdrawals
   - User calls withdraw(asset, amount, recipient).
   - Default recipient should be msg.sender.
   - If recipient differs, require explicit user authorisation or signed intent.
   - Use CEI and nonReentrant.
   - Use SafeERC20 for ERC-20 and call for ETH.
   - Emit WithdrawalClaimed.
3. Escrow integration
   - Escrow resolution/release/refund marks balances claimable.
   - Escrow cannot be withdrawn twice.
   - Disputed escrows cannot be withdrawn until resolved.
   - Governance changes must not affect active escrow withdrawal rules.
4. Resolver bonds
   - Bond withdrawal requires no active cases, no pending slash, and exit delay elapsed.
   - Slash exposure is snapshotted at verdict/assignment time.
   - Slashing has priority over withdrawal.
5. Automation boundaries
   - Automation may mark funds claimable.
   - Automation may unwind yield back to escrow custody.
   - Automation must not choose recipients or push funds to users unless executing a user-signed withdrawal intent.
6. Tests
   - Fuzz all withdrawal paths.
   - Add malicious recipient reentrancy tests.
   - Add ERC-20 non-standard return tests.
   - Add failing recipient tests.
   - Add double-withdrawal tests.
   - Add governance-redirection tests.
   - Add pause-withdrawal tests.
   - Add resolver-bond-withdraw-before-slash tests.
22. Recommended default for Sew
For Sew Protocol specifically, I would use this policy:
Escrow release/refund/resolution:
  creates claimable balance
User/seller/buyer:
  explicitly claims funds
Resolver:
  never transfers user funds directly
Governance:
  cannot redirect, seize, or rewrite active claims
Yield module:
  only returns funds to escrow
Automation:
  can update eligibility and unwind yield
  cannot push funds to arbitrary users
This is the cleanest alignment between:
- smart-contract security
- non-custodial architecture
- neutral infrastructure posture
- regulatory simplicity
- dispute-resolution credibility
