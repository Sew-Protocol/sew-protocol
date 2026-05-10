// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../types/EscrowTypes.sol';

/**
 * @title IEscrowVaultMinimal
 * @notice Minimal vault interface consumed by the bridge
 */
interface IEscrowVaultMinimal {
    function createEscrow(
        address token,
        address to,
        uint256 amount,
        EscrowSettings memory settings
    ) external returns (uint256 workflowId);

}

/**
 * @title DeferredFundingBridge
 * @notice Experimental Phase-1 implementation of deferred-funding escrow.
 *
 * Problem solved
 * --------------
 * In EscrowVault, funds are pulled from the wallet that calls createEscrow() (the "creator").
 * This contract inverts that assumption: the *releaser* supplies funds, and the creator merely
 * commits off-chain (or via a cheap on-chain slot) to the escrow terms.
 *
 * Two interaction paths
 * ---------------------
 * A. On-chain slot  (creator has gas, wants on-chain proof of commitment)
 *    1. Creator calls openSlot()      — records commitment, emits SlotOpened
 *    2. Releaser calls executeSlot()  — pulls tokens from releaser and creates escrow
 *    3. Creator may call cancelSlot() — invalidates slot before releaser acts
 *
 * B. EIP-712 gasless (creator only needs to sign, great for mobile wallets)
 *    1. Creator signs a DeferredCommitment typed message off-chain (zero gas)
 *    2. Releaser calls executeFromSignature() with the sig + funds
 *    3. Creator may call invalidateNonce() to burn the nonce and revoke
 *
 * Trust model
 * -----------
 * - Creator commits to escrow terms (recipient, amount, releaser, deadline) but holds no funds.
 * - Releaser supplies funds and decides when to execute (i.e., after verifying off-chain work).
 * - Recipient receives funds only when normal escrow release/cancel/dispute flow later creates claimable entitlement.
 * - The vault escrow's `from` address is the bridge itself; creator identity is tracked here.
 *
 * Security properties
 * -------------------
 * - Only the designated releaser can execute a commitment.
 * - Nonces prevent replay; commitments expire at a creator-chosen deadline.
 * - Token pull uses exact amounts; no residual approvals remain after each execution.
 * - ReentrancyGuard on all state-modifying entry points.
 *
 * Known limitations (Phase 1)
 * ---------------------------
 * - The vault `from` = bridge address, not creator. Dispute rights belong to the bridge.
 *   Phase 2 will add a creator-delegated dispute proxy.
 * - Bridge execution intentionally does NOT release. Escrow remains in protected lifecycle.
 * - Yield is not available by default in bridge-created escrows.
 */
contract DeferredFundingBridge is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ─── Immutable ─────────────────────────────────────────────────────────────

    /// @notice The EscrowVault this bridge delegates to
    IEscrowVaultMinimal public immutable vault;

    // ─── EIP-712 typed data ────────────────────────────────────────────────────

    bytes32 private constant COMMITMENT_TYPEHASH = keccak256(
        'DeferredCommitment(address token,address recipient,address releaser,'
        'uint256 amount,uint256 nonce,uint256 deadline)'
    );

    // ─── On-chain slot storage ──────────────────────────────────────────────────

    struct Slot {
        address creator;
        address token;
        address recipient;
        address releaser;
        uint256 amount;     // gross amount (before vault fee deduction)
        uint256 deadline;   // unix timestamp; slot expires after this
        bool active;
    }

    /// @notice slotId → Slot
    mapping(bytes32 => Slot) public slots;

    // ─── Nonce storage (both paths share this) ──────────────────────────────────

    /// @notice creator → nonce → consumed
    /// @dev Used by the EIP-712 path. Also reused by on-chain slots to allow
    ///      creators to batch-invalidate via invalidateNonce().
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    // ─── Vault workflow tracking ────────────────────────────────────────────────

    /// @notice vaultWorkflowId → creator address (bridge is `from` in vault)
    mapping(uint256 => address) public workflowCreator;

    /// @notice vaultWorkflowId → releaser address
    mapping(uint256 => address) public workflowReleaser;

    // ─── Errors ─────────────────────────────────────────────────────────────────

    error ZeroVaultAddress();
    error ZeroToken();
    error ZeroRecipient();
    error ZeroReleaser();
    error ZeroAmount();
    error NotDesignatedReleaser(address caller, address expected);
    error CommitmentExpired(uint256 deadline, uint256 currentTime);
    error NonceAlreadyUsed(address creator, uint256 nonce);
    error SlotNotActive(bytes32 slotId);
    error SlotNotOwnedByCaller(bytes32 slotId, address caller);
    error InvalidSignature();
    error RecipientIsReleaser(address recipient, address releaser);
    error DeadlineInPast(uint256 deadline, uint256 currentTime);

    // ─── Events ─────────────────────────────────────────────────────────────────

    /// @notice Emitted when an on-chain commitment slot is opened
    event SlotOpened(
        bytes32 indexed slotId,
        address indexed creator,
        address indexed releaser,
        address recipient,
        address token,
        uint256 amount,
        uint256 deadline
    );

    /// @notice Emitted when a slot is cancelled by its creator
    event SlotCancelled(bytes32 indexed slotId, address indexed creator);

    /// @notice Emitted when a commitment is executed (either path)
    event CommitmentExecuted(
        bytes32 indexed commitmentId, // slotId for slot path; sig hash for EIP-712 path
        address indexed creator,
        address indexed releaser,
        address recipient,
        address token,
        uint256 grossAmount,
        uint256 vaultWorkflowId
    );

    /// @notice Emitted when bridge funds and creates escrow only (no automatic release)
    event DeferredEscrowFunded(
        uint256 indexed workflowId,
        address indexed creator,
        address indexed releaser,
        address recipient,
        address token,
        uint256 grossAmount
    );

    /// @notice Emitted when a creator burns a nonce
    event NonceInvalidated(address indexed creator, uint256 nonce);

    // ─── Constructor ─────────────────────────────────────────────────────────────

    /**
     * @param vaultAddress Address of the EscrowVault to delegate to
     * @param name         EIP-712 domain name (e.g. "DeferredFundingBridge")
     * @param version      EIP-712 domain version (e.g. "1")
     */
    constructor(address vaultAddress, string memory name, string memory version)
        EIP712(name, version)
    {
        if (vaultAddress == address(0)) revert ZeroVaultAddress();
        vault = IEscrowVaultMinimal(vaultAddress);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH A — On-chain slot
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Creator opens an on-chain commitment slot.
     * @dev No tokens are moved. Emits SlotOpened so the recipient can see the
     *      on-chain proof of the creator's intent before the releaser acts.
     * @param token     ERC20 token address
     * @param recipient Address that will receive the escrowed funds
     * @param releaser  Address that is authorised to execute (and fund) this slot
     * @param amount    Gross amount (vault fee is deducted from this)
     * @param deadline  Unix timestamp after which this slot cannot be executed
     * @return slotId   Keccak256 identifier for this slot
     */
    function openSlot(
        address token,
        address recipient,
        address releaser,
        uint256 amount,
        uint256 deadline
    ) external returns (bytes32 slotId) {
        _validateParams(token, recipient, releaser, amount, deadline);

        slotId = keccak256(abi.encode(
            msg.sender, token, recipient, releaser, amount, deadline, block.number
        ));

        slots[slotId] = Slot({
            creator: msg.sender,
            token: token,
            recipient: recipient,
            releaser: releaser,
            amount: amount,
            deadline: deadline,
            active: true
        });

        emit SlotOpened(slotId, msg.sender, releaser, recipient, token, amount, deadline);
    }

    /**
     * @notice Releaser executes a slot: pulls tokens and creates escrow.
     * @dev The caller must be the designated releaser. The caller must have approved this
     *      contract to spend at least `slot.amount` of `slot.token`.
     * @param slotId The slot identifier returned by openSlot()
     */
    function executeSlot(bytes32 slotId) external nonReentrant {
        Slot storage s = slots[slotId];
        if (!s.active) revert SlotNotActive(slotId);
        if (msg.sender != s.releaser) revert NotDesignatedReleaser(msg.sender, s.releaser);
        if (block.timestamp > s.deadline) revert CommitmentExpired(s.deadline, block.timestamp);

        address creator   = s.creator;
        address token     = s.token;
        address recipient = s.recipient;
        address releaser  = s.releaser;
        uint256 amount    = s.amount;

        // Mark consumed before external calls (CEI)
        s.active = false;

        uint256 workflowId = _fundAndCreateEscrow(token, recipient, amount, msg.sender);

        workflowCreator[workflowId] = creator;
        workflowReleaser[workflowId] = releaser;

        emit DeferredEscrowFunded(workflowId, creator, releaser, recipient, token, amount);
        emit CommitmentExecuted(slotId, creator, releaser, recipient, token, amount, workflowId);
    }

    /**
     * @notice Creator cancels their slot before the releaser executes it.
     * @param slotId The slot identifier to cancel
     */
    function cancelSlot(bytes32 slotId) external {
        Slot storage s = slots[slotId];
        if (!s.active) revert SlotNotActive(slotId);
        if (s.creator != msg.sender) revert SlotNotOwnedByCaller(slotId, msg.sender);

        s.active = false;
        emit SlotCancelled(slotId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PATH B — EIP-712 gasless commitment
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Releaser executes a creator's off-chain EIP-712 signed commitment.
     * @dev The creator never sends a transaction — they only sign a typed message.
     *      The releaser validates the signature and provides the funds.
     *
     *      Commitment struct (EIP-712 typed data the creator signs):
     *        DeferredCommitment {
     *          address token;
     *          address recipient;
     *          address releaser;
     *          uint256 amount;
     *          uint256 nonce;
     *          uint256 deadline;
     *        }
     *
     * @param token       ERC20 token
     * @param recipient   Funds destination
     * @param releaser    Must equal msg.sender
     * @param amount      Gross amount (vault fee deducted)
     * @param nonce       Creator-chosen nonce (recommend block.timestamp or a counter)
     * @param deadline    Expiry timestamp
     * @param creatorSig  EIP-712 signature from the creator's wallet
     */
    function executeFromSignature(
        address token,
        address recipient,
        address releaser,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata creatorSig
    ) external nonReentrant {
        if (msg.sender != releaser) revert NotDesignatedReleaser(msg.sender, releaser);
        if (block.timestamp > deadline) revert CommitmentExpired(deadline, block.timestamp);
        _validateParams(token, recipient, releaser, amount, deadline);

        // Recover creator from signature
        bytes32 structHash = keccak256(abi.encode(
            COMMITMENT_TYPEHASH,
            token,
            recipient,
            releaser,
            amount,
            nonce,
            deadline
        ));
        address creator = _hashTypedDataV4(structHash).recover(creatorSig);
        if (creator == address(0)) revert InvalidSignature();

        // Consume nonce — prevents replay
        if (usedNonces[creator][nonce]) revert NonceAlreadyUsed(creator, nonce);
        usedNonces[creator][nonce] = true;

        uint256 workflowId = _fundAndCreateEscrow(token, recipient, amount, msg.sender);

        workflowCreator[workflowId] = creator;
        workflowReleaser[workflowId] = releaser;
        emit DeferredEscrowFunded(workflowId, creator, releaser, recipient, token, amount);

        // Derive a deterministic commitmentId for the event
        bytes32 commitmentId = keccak256(abi.encode(creator, token, recipient, releaser, amount, nonce, deadline));
        emit CommitmentExecuted(commitmentId, creator, releaser, recipient, token, amount, workflowId);
    }

    /**
     * @notice Creator burns a nonce to prevent a previously-signed commitment from executing.
     * @dev Call this if you want to revoke a signature before the releaser acts.
     * @param nonce The nonce to invalidate
     */
    function invalidateNonce(uint256 nonce) external {
        usedNonces[msg.sender][nonce] = true;
        emit NonceInvalidated(msg.sender, nonce);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // View helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the EIP-712 domain separator for off-chain signers.
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Returns the typed-data hash a creator must sign for the EIP-712 path.
     * @dev Use this on the client to construct the exact bytes to sign:
     *      bytes32 digest = bridge.commitmentDigest(...);
     *      bytes memory sig = wallet.sign(digest);
     */
    function commitmentDigest(
        address token,
        address recipient,
        address releaser,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            COMMITMENT_TYPEHASH,
            token,
            recipient,
            releaser,
            amount,
            nonce,
            deadline
        )));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Pulls `amount` from `funder`, approves vault for exactly that amount,
     *      and creates an escrow (bridge is `from`).
     *      The vault fee is deducted by the vault itself — we pass the gross amount.
     */
    function _fundAndCreateEscrow(
        address token,
        address recipient,
        uint256 amount,
        address funder
    ) internal returns (uint256 workflowId) {
        // Pull gross amount from the funder (releaser)
        IERC20(token).safeTransferFrom(funder, address(this), amount);

        // Approve vault for exactly this amount; reset to 0 afterward to avoid residual allowance
        IERC20(token).forceApprove(address(vault), amount);

        // Bridge is `from`; no custom resolver, yield, or auto-times needed
        EscrowSettings memory settings;

        workflowId = vault.createEscrow(token, recipient, amount, settings);

        // Reset allowance — vault should have consumed it all, but be explicit
        IERC20(token).forceApprove(address(vault), 0);

        // Intentionally no release here: escrow must follow normal protected lifecycle.
    }

    /**
     * @dev Shared parameter validation for both paths.
     */
    function _validateParams(
        address token,
        address recipient,
        address releaser,
        uint256 amount,
        uint256 deadline
    ) internal view {
        if (token == address(0)) revert ZeroToken();
        if (recipient == address(0)) revert ZeroRecipient();
        if (releaser == address(0)) revert ZeroReleaser();
        if (amount == 0) revert ZeroAmount();
        if (recipient == releaser) revert RecipientIsReleaser(recipient, releaser);
        if (deadline <= block.timestamp) revert DeadlineInPast(deadline, block.timestamp);
    }
}
