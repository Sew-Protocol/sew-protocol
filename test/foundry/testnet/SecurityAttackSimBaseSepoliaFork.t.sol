// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

import { EscrowSettings, EscrowState } from "../../../contracts/types/EscrowTypes.sol";
import { YieldPreset } from "../../../contracts/types/YieldPresets.sol";

interface IEscrowVaultAttackTarget {
    function escrowFee() external view returns (uint256);
    function escrowFeeAddress() external view returns (address);

    function totalFeesPerToken(address token) external view returns (uint256);
    function withdrawFees(address token) external returns (bool);

    function createEscrow(address token, address to, uint256 amount, EscrowSettings memory settings)
        external
        returns (uint256 workflowId);

    function releaseEscrowTransfer(uint256 workflowId) external returns (bool);

    function escrowTransfers(uint256 workflowId)
        external
        view
        returns (
            address token,
            address to,
            address from,
            address disputeResolver,
            uint256 amountAfterFee,
            uint64 autoReleaseTime,
            uint64 autoCancelTime,
            EscrowState escrowState,
            uint8 senderStatus,
            uint8 recipientStatus
        );

    function claimableBalances(uint256 workflowId, address who) external view returns (uint256);
    function withdrawEscrow(uint256 workflowId) external returns (uint256);
}

interface IERC20Like {
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract MaliciousReenteringERC20 {
    string public name = "ReenterToken";
    string public symbol = "REENT";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Reentrancy hook configuration
    address public target;
    bytes public callData;
    bool public shouldReenter;
    bool public returnFalseOnTransfer; // used to force claimable fallback
    bool internal _inHook;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function setReentry(address target_, bytes calldata data, bool enabled) external {
        target = target_;
        callData = data;
        shouldReenter = enabled;
    }

    function setReturnFalseOnTransfer(bool v) external {
        returnFalseOnTransfer = v;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _maybeReenter();

        if (returnFalseOnTransfer) {
            // Simulate a token that signals failure and performs no state change.
            // (If a token transfers but returns false, it can create misleading "fallback-to-claimable"
            // signals even though funds moved; that's a separate edge-case worth documenting.)
            return false; // force EscrowVault to fall back to claimable
        }

        if (balanceOf[msg.sender] < amount) revert("ERC20: transfer amount exceeds balance");
        unchecked {
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _maybeReenter();

        uint256 a = allowance[from][msg.sender];
        if (a < amount) revert("ERC20: insufficient allowance");
        if (balanceOf[from] < amount) revert("ERC20: transfer amount exceeds balance");
        unchecked {
            allowance[from][msg.sender] = a - amount;
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }

    function _maybeReenter() internal {
        if (!shouldReenter || _inHook || target == address(0) || callData.length == 0) return;
        _inHook = true;
        // Best-effort: we want to observe whether reentrancy can steal, not brick the token transfer.
        (bool ok, ) = target.call(callData);
        ok; // ignore
        _inHook = false;
    }
}

contract SecurityAttackSimBaseSepoliaForkTest is Test {
    using stdJson for string;

    string internal RPC_URL;
    uint256 internal FORK_BLOCK;

    address internal escrowVaultAddr;
    IEscrowVaultAttackTarget internal escrow;

    function setUp() public {
        RPC_URL = vm.envOr("RPC_BASE_SEPOLIA", string("https://sepolia.base.org"));
        FORK_BLOCK = vm.envOr("FORK_BLOCK_NUMBER", uint256(0)); // 0 = latest
        if (FORK_BLOCK > 0) vm.createSelectFork(RPC_URL, FORK_BLOCK);
        else vm.createSelectFork(RPC_URL);

        escrowVaultAddr = _dep("EscrowVault");
        escrow = IEscrowVaultAttackTarget(escrowVaultAddr);
    }

    // ============
    // Attack 0: try to steal fees (should revert unless fee recipient role)
    // ============
    function test_attack_withdrawFees_should_not_be_callable_by_random_eoa() public {
        address attacker = makeAddr("attacker");
        address token = _dep("SewToken"); // any token address; call will revert if no fees or no role

        vm.prank(attacker);
        vm.expectRevert();
        escrow.withdrawFees(token);
    }

    // ============
    // Attack 1: reenter during createEscrow transferFrom
    // - token tries to call releaseEscrowTransfer(0) mid-create
    // - createEscrow is nonReentrant, so reentry should fail and not steal
    // ============
    function test_attack_reenter_during_create_does_not_break_or_steal() public {
        address buyer = makeAddr("buyer");
        address seller = makeAddr("seller");

        MaliciousReenteringERC20 tkn = new MaliciousReenteringERC20();
        tkn.mint(buyer, 1_000_000e18);

        // Configure token: attempt to reenter escrow during transferFrom
        // (This should fail due to nonReentrant / invalid workflow id).
        bytes memory data = abi.encodeWithSelector(IEscrowVaultAttackTarget.releaseEscrowTransfer.selector, uint256(0));
        tkn.setReentry(escrowVaultAddr, data, true);

        vm.startPrank(buyer);
        tkn.approve(escrowVaultAddr, type(uint256).max);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 wid = escrow.createEscrow(address(tkn), seller, 100e18, settings);
        vm.stopPrank();

        // If create succeeded, attacker didn't steal anything. Assert escrow is pending.
        ( , , address from, , uint256 amountAfterFee, , , EscrowState st, , ) = escrow.escrowTransfers(wid);
        assertEq(from, buyer, "from should be buyer");
        assertEq(uint8(st), uint8(EscrowState.PENDING), "escrow should be PENDING");
        assertEq(amountAfterFee, 100e18, "amountAfterFee expected (fee bps is 0 on testnet)");
    }

    // ============
    // Attack 2: reenter during release token.transfer
    // - token calls back into withdrawFees during transfer
    // - releaseEscrowTransfer is nonReentrant so reentry should not succeed
    // ============
    function test_attack_reenter_during_release_does_not_drain_fees() public {
        address buyer = makeAddr("buyer");
        address seller = makeAddr("seller");

        MaliciousReenteringERC20 tkn = new MaliciousReenteringERC20();
        tkn.mint(buyer, 1_000_000e18);

        // Attempt to call withdrawFees during token.transfer
        bytes memory data = abi.encodeWithSelector(IEscrowVaultAttackTarget.withdrawFees.selector, address(tkn));
        tkn.setReentry(escrowVaultAddr, data, true);

        vm.startPrank(buyer);
        tkn.approve(escrowVaultAddr, type(uint256).max);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 wid = escrow.createEscrow(address(tkn), seller, 100e18, settings);
        // Release should succeed; reentrant withdrawFees attempt should fail (no role / nonReentrant)
        escrow.releaseEscrowTransfer(wid);
        vm.stopPrank();

        // Funds should go to seller (push succeeds because token returns true).
        assertEq(tkn.balanceOf(seller), 100e18, "seller should receive escrowed amount");

        (, , , , , , , EscrowState st, , ) = escrow.escrowTransfers(wid);
        assertEq(uint8(st), uint8(EscrowState.RELEASED), "escrow should be RELEASED");
    }

    // ============
    // Attack 3: force claimable fallback, then attempt "double withdraw" via reentrancy
    // - token.transfer returns false => claimable credited
    // - during withdrawEscrow(), token tries to reenter withdrawEscrow again
    // - should not allow draining twice (claimable is zeroed first + nonReentrant)
    // ============
    function test_attack_double_withdraw_reentrancy_fails_and_cannot_steal() public {
        address buyer = makeAddr("buyer");
        address seller = makeAddr("seller");

        MaliciousReenteringERC20 tkn = new MaliciousReenteringERC20();
        tkn.mint(buyer, 1_000_000e18);

        vm.startPrank(buyer);
        tkn.approve(escrowVaultAddr, type(uint256).max);
        EscrowSettings memory settings = EscrowSettings({
            customResolver: address(0),
            yieldPreset: YieldPreset.OFF,
            autoReleaseTime: 0,
            autoCancelTime: 0
        });
        uint256 wid = escrow.createEscrow(address(tkn), seller, 100e18, settings);

        // Force push failure (return false) so escrow falls back to claimable.
        tkn.setReturnFalseOnTransfer(true);
        escrow.releaseEscrowTransfer(wid);
        vm.stopPrank();

        // Claimable should be set for seller.
        uint256 claimable = escrow.claimableBalances(wid, seller);
        assertEq(claimable, 100e18, "claimable should equal amountAfterFee");
        assertEq(tkn.balanceOf(seller), 0, "seller should not have received tokens via push");

        // Configure token to attempt reenter withdrawEscrow during payout transfer.
        bytes memory data = abi.encodeWithSelector(IEscrowVaultAttackTarget.withdrawEscrow.selector, wid);
        tkn.setReentry(escrowVaultAddr, data, true);
        tkn.setReturnFalseOnTransfer(false); // allow transfer to go through for the outer withdraw

        // Withdraw as seller. Even if token tries to reenter, it must not drain twice.
        vm.prank(seller);
        escrow.withdrawEscrow(wid);

        assertEq(tkn.balanceOf(seller), 100e18, "seller should receive exactly once");
        assertEq(escrow.claimableBalances(wid, seller), 0, "claimable should be cleared");
    }

    // ---- deployments json helpers (copied pattern from Phase0/Phase1) ----
    function _dep(string memory name) internal view returns (address) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments/baseSepolia/", name, ".json");
        string memory raw = vm.readFile(path);
        address addr = raw.readAddress(".address");
        require(addr != address(0), "deployment address is zero");
        return addr;
    }
}

