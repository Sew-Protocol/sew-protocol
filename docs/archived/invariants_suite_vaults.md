Vault Behavior Testing Playbook (Foundry + forge-std) for Yield Modules
-----------------------------------------------------------------------

**Audience:** Cursor (you + agents)\
**Goal:** Catch "we're reinventing a standard" early, keep BaseEscrow generic, and make yield modules swappable with confidence.

* * * * *

1) Why this exists
==================

When you integrate yield (Aave v3 today, others later), there are two recurring failure modes:

1.  **Protocol leakage** into core contracts (BaseEscrow starts knowing about aTokens/scaled balances/etc.).

2.  You recreate a standard (usually **ERC-4626**) without realizing it, and the codebase grows + tests become brittle.

forge-std can't tell you "use ERC-4626", but it *can* force you to write **statements** about assets/shares/value/withdraw semantics. If those statements look like a standard, that's your signal.

* * * * *

2) "Statements" you should write (and why they detect standards)
================================================================

Treat these as executable requirements. They are the bridge from "design intent" → "code shape".

### 2.1 Assertions (local truths in a specific test)

Use when you're validating a single flow.

**Examples**

-   `shares > 0 after deposit(assets)`

-   `assetsOut >= principal` (in positive-yield scenario)

-   `totalAssets` changes correctly after deposit/withdraw (if you expose it)

**Helpful Foundry patterns**

-   `assertEq(a, b)`

-   `assertGt(a, b)` / `assertGe(a, b)`

-   `assertApproxEqAbs(a, b, tolerance)`

-   `assertApproxEqRel(a, b, relToleranceBpsOrWad)`

> Design signal: when most assertions talk about `assets`, `shares`, `convertToAssets/convertToShares`, you're in ERC-4626 territory.

### 2.2 Invariants (global truths across arbitrary action sequences)

Use when behavior must hold across deposits, partial withdrawals, many escrows, time passing, etc.

> Design signal: if your invariants are about "share price", "round trip", "monotonic value", "conservation", you want a vault abstraction.

### 2.3 Assumptions (`vm.assume`) (defining valid input domains)

Use to keep fuzzing meaningful and safe.

-   assume non-zero amounts

-   assume addresses are not special (0, this, etc.)

-   assume bounds to avoid overflow/revert noise

-   assume preconditions (e.g., vault enabled)

> Design signal: if you're assuming "receipt token exists" or "balance maps to value via ratio", that's a standard-shaped primitive.

* * * * *

3) Workflow: "Standards detector" loop (Cursor-friendly)
========================================================

Use this every time yield logic changes or a new yield module is proposed.

Step A --- Behavior-first spec (no protocol words)
------------------------------------------------

Create a test file named like:

-   `VaultBehavior.t.sol` or `YieldModuleBehavior.t.sol`

Rules:

-   **Do not mention Aave/aToken/scaled balance** in test names or comments.

-   Only talk in `assets` and `shares`.

If you can express 90% of your requirements without protocol terms, you almost certainly want:

-   ERC-4626, or

-   a minimal 4626-like internal interface.

Step B --- Implementation tests (protocol words allowed)
------------------------------------------------------

Then write Aave-specific tests:

-   correct pool interactions

-   proper approvals

-   reserve configuration quirks

-   failure modes

This isolates protocol complexity from core behavior.

Step C --- PR/Review gate
-----------------------

Every yield-related PR must include:

-   the behavior suite runs

-   invariants pass

-   a short "Standards Scan" section (primitive → candidate standards → adopt/decline)

* * * * *

4) Templates you can paste into Cursor
======================================

4.1 PR template snippet (minimal friction)
------------------------------------------

Paste into `.github/pull_request_template.md` (or your internal PR notes):

-   **Standards Scan**

    -   Primitive: `__________` (e.g., "tokenized vault / receipt shares for yield")

    -   Candidate standards: `__________` (e.g., ERC-4626)

    -   Decision: adopt / adapter / custom

    -   If not adopting: 1--2 reasons + implications

-   **Behavior Suite**

    -   `VaultBehavior` tests pass

    -   invariants pass

    -   fuzz tests include boundary assumptions

4.2 Cursor prompt: Standards check for a diff
---------------------------------------------

> "Review this diff and list any places where the code introduces receipt tokens/shares, deposit-withdraw semantics, or value conversion. Suggest the closest ERC/EIP or de-facto interface fit, and the smallest change to align."

4.3 Cursor prompt: Generate behavior tests first
------------------------------------------------

> "Write forge-std tests for a generic yield module expressed only in assets/shares terms. Do not mention Aave. Provide unit tests + fuzz tests + invariants."

* * * * *

5) Template invariant suite for vault behavior
==============================================

This suite assumes you can call into a "vault-like" interface. If you're not fully ERC-4626 compliant, implement a minimal adapter with the same semantics.

### 5.1 Minimal interface for tests (drop-in)

Use this even if production uses a different interface; your harness can adapt.

`interface IVaultLike {
    function asset() external view returns (address);

    // Core actions
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // Conversions
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    // Accounting
    function totalAssets() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256 shares);
} `

If your yield module is not itself a vault token, create a thin harness contract that:

-   holds the receipt token

-   forwards calls

-   exposes these functions for test purposes

### 5.2 Invariants (copy-paste suite)

These are written to be robust across rounding and small time deltas. Adjust tolerances for your token decimals + expected yield model.

**Invariant categories**

1.  Round-trip / consistency

2.  Monotonicity (when applicable)

3.  Conservation & isolation

4.  Bounds & non-negativity

5.  Equivalence of "withdraw all" paths

Below is a concrete suite skeleton.

`// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IVaultLike {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function totalAssets() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256 shares);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * Vault Behavior Invariant Suite
 * - Works for ERC-4626 or an ERC-4626-like adapter.
 * - No protocol-specific assumptions (Aave, aToken, scaled balances) appear here.
 */
contract VaultBehaviorInvariants is Test {
    IVaultLike internal vault;
    IERC20 internal underlying;

    address internal userA = address(0xA11CE);
    address internal userB = address(0xB0B);

    // Tune tolerances per token decimals / rounding expectations
    uint256 internal absTol = 3; // small absolute tolerance in smallest units (e.g., 3 wei for 18dp, or 3 units for 6dp)
    uint256 internal relTolBps = 5; // 0.05% relative tolerance (basis points)

    function setUp() public {
        // wire your deployed vault/adapter here in concrete test
        // vault = IVaultLike(<address>);
        // underlying = IERC20(vault.asset());

        // fund users in your concrete test harness
        // deal(address(underlying), userA, 1_000_000e6);
        // deal(address(underlying), userB, 1_000_000e6);
    }

    // ---------- Helper assertions ----------

    function _assertApproxEqRelBps(uint256 a, uint256 b, uint256 bps, string memory err) internal {
        if (a == b) return;
        uint256 diff = a > b ? a - b : b - a;
        uint256 denom = b == 0 ? 1 : b;
        // diff/denom <= bps/10000  => diff*10000 <= denom*bps
        assertLe(diff * 10_000, denom * bps, err);
    }

    // ---------- Invariants ----------

    /// 1) Conversion sanity: convertToAssets(convertToShares(x)) ~= x (within rounding)
    function invariant_convert_round_trip_assets() public {
        uint256 x = bound(uint256(keccak256("x")), 1, 1e18); // replace with token-aware bounds in concrete impl
        uint256 shares = vault.convertToShares(x);
        uint256 back = vault.convertToAssets(shares);

        // back should not exceed x by more than rounding artifacts; allow small tolerance
        // Many vaults round down on convertToShares and/or convertToAssets
        assertLe(back, x + absTol, "round-trip assets too high");
        // and should not be wildly smaller either
        _assertApproxEqRelBps(back, x, relTolBps, "round-trip assets deviates too much");
    }

    /// 2) Conversion sanity: convertToShares(convertToAssets(s)) ~= s
    function invariant_convert_round_trip_shares() public {
        uint256 s = bound(uint256(keccak256("s")), 1, 1e18);
        uint256 assets = vault.convertToAssets(s);
        uint256 back = vault.convertToShares(assets);

        assertLe(back, s + absTol, "round-trip shares too high");
        _assertApproxEqRelBps(back, s, relTolBps, "round-trip shares deviates too much");
    }

    /// 3) Non-negativity: conversions never go negative (trivial in uint), and assets/shares for nonzero input should be >= 0.
    /// Also: if assets>0, shares should generally be >0 unless vault is pathological.
    function invariant_nonzero_assets_give_nonzero_shares() public {
        uint256 x = bound(uint256(keccak256("x2")), 1, 1e18);
        uint256 shares = vault.convertToShares(x);
        assertGt(shares + 0, 0, "nonzero assets -> zero shares");
    }

    /// 4) Total assets consistency (weak form):
    /// totalAssets should be >= value represented by sum of user share balances (in asset terms), within rounding.
    /// This catches "phantom shares" and accounting drift.
    function invariant_totalAssets_covers_user_value() public {
        uint256 aShares = vault.balanceOf(userA);
        uint256 bShares = vault.balanceOf(userB);

        uint256 userValue = vault.convertToAssets(aShares) + vault.convertToAssets(bShares);
        uint256 ta = vault.totalAssets();

        // totalAssets should cover at least the represented value (rounding can cut either way; keep this weak)
        assertGe(ta + absTol, userValue, "totalAssets under user represented value");
    }

    /// 5) Monotonic share value (only if vault has non-negative yield and no losses):
    /// convertToAssets(1eN shares) should not decrease across time/actions.
    /// If your system can lose funds, gate this invariant off or soften it.
    function invariant_share_value_not_decreasing_when_no_losses() public {
        uint256 unitShares = 1e12; // choose a unit large enough to avoid rounding to zero
        uint256 v1 = vault.convertToAssets(unitShares);

        // simulate time / yield accrual in your concrete handler if applicable
        // skip here; invariant suite is generic

        uint256 v2 = vault.convertToAssets(unitShares);
        assertGe(v2 + absTol, v1, "share value decreased");
    }
} `

### 5.3 Stateful fuzzing with a Handler (recommended)

To make invariants meaningful, you want randomized action sequences. Foundry's standard approach: a `Handler` contract with methods like `depositA`, `depositB`, `redeemA`, etc.

Template:

`contract VaultHandler is Test {
    IVaultLike public vault;
    IERC20 public underlying;

    address public userA;
    address public userB;

    constructor(IVaultLike _vault, address _userA, address _userB) {
        vault = _vault;
        underlying = IERC20(_vault.asset());
        userA = _userA;
        userB = _userB;
    }

    function depositA(uint256 assets) external {
        assets = bound(assets, 1, underlying.balanceOf(userA));
        vm.startPrank(userA);
        underlying.approve(address(vault), assets);
        vault.deposit(assets, userA);
        vm.stopPrank();
    }

    function depositB(uint256 assets) external {
        assets = bound(assets, 1, underlying.balanceOf(userB));
        vm.startPrank(userB);
        underlying.approve(address(vault), assets);
        vault.deposit(assets, userB);
        vm.stopPrank();
    }

    function redeemA(uint256 shares) external {
        uint256 bal = vault.balanceOf(userA);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);

        vm.startPrank(userA);
        vault.redeem(shares, userA, userA);
        vm.stopPrank();
    }

    function redeemB(uint256 shares) external {
        uint256 bal = vault.balanceOf(userB);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);

        vm.startPrank(userB);
        vault.redeem(shares, userB, userB);
        vm.stopPrank();
    }
} `

Then, in your invariant test:

`function setUp() public {
    // deploy/wire vault + underlying, fund users
    handler = new VaultHandler(vault, userA, userB);
    targetContract(address(handler)); // Foundry will call handler methods randomly
} `

> This is where forge-std really shines: it turns your "vault behavior" spec into something that must hold under arbitrary sequences --- exactly what breaks when you leak protocol specifics into core logic.

* * * * *

6) Aave v3-specific add-ons (kept separate)
===========================================

Keep these out of the generic suite. Put in `AaveYieldModule.t.sol` or similar:

-   deposit/withdraw uses correct pool addresses

-   aToken address registration correct

-   approval handling correct

-   revert conditions on unsupported token

-   yield accrual simulation (mock pool that increases index / balance)

-   emergency unwind constraints (limits per call)

This separation prevents "BaseEscrow knows Aave" creeping back in.

* * * * *

7) How this helps you catch standards earlier
=============================================

If your earliest tests are phrased as:

-   `deposit assets -> shares`

-   `redeem shares -> assets`

-   conversions round-trip

-   share value monotonic (if no losses)

-   totalAssets covers user value

...you will naturally ask "is there an ERC for this?" before writing bespoke tracking like `escrowATokenBalances`.

That's the standards detector.

* * * * *

### Assumptions

-   You can provide an ERC-4626-like surface for testing even if the production module uses different names (via a small adapter/harness).

-   Your yield strategy is expected to be non-lossy in the "normal" case (if losses are possible, we'll soften/disable the monotonic invariant).

-   You're comfortable using a Handler-based invariant suite for stateful fuzzing.

### Next steps

-   Add the PR template snippet and require "behavior suite passes" for yield-related changes.

-   Implement a tiny adapter so your Aave module can be tested via `IVaultLike` (even before you fully refactor contracts).

-   Wire the Handler-based invariant suite into CI so it runs on every PR touching yield logic.
