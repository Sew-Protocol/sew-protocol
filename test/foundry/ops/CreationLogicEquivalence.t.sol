// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import 'forge-std/Test.sol';
import '../../mocks/legacy/CreateOpsReference.sol';
import '../../../contracts/libraries/EscrowCreationLogic.sol';
import '../../../contracts/types/EscrowTypes.sol';
import '../../../contracts/types/YieldPresets.sol';

/// @notice Configurable resolution module for exercising resolver lookup branches.
contract CreateResolverModule {
    address internal resolver;
    bool internal revertLookup;
    bool internal shortReturn;

    function setResolver(address r) external {
        resolver = r;
    }

    function setRevertLookup(bool r) external {
        revertLookup = r;
    }

    function setShortReturn(bool s) external {
        shortReturn = s;
    }

    function getDisputeResolver(uint256, address, bytes calldata) external view returns (address, uint8) {
        require(!revertLookup, 'lookup revert');
        if (shortReturn) {
            // Return malformed/short data via assembly by returning nothing useful
            assembly {
                mstore(0x00, 0)
                return(0x00, 0)
            }
        }
        return (resolver, 0);
    }
}

/// @notice Differential assurance: EscrowCreationLogic must reproduce the frozen
///         CreateOpsReference oracle exactly across creation inputs AND the two policy
///         flags (resolverMustBeContract, yieldDepositsPaused), including
///         success/revert classification. Evidence that removing the external
///         boundary does not silently redesign escrow creation.
contract CreationLogicEquivalenceTest is Test {
    CreateOpsReference internal createOps;
    CreateResolverModule internal module;
    address internal contractResolver;

    address internal constant SENDER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xB0B);

    function setUp() public {
        createOps = new CreateOpsReference(address(this));
        createOps.registerEscrowContract(address(this));
        module = new CreateResolverModule();
        contractResolver = address(module); // any deployed contract
        vm.warp(1_000_000);
    }

    function _settings(
        address customResolver,
        address releaseAddress,
        uint8 presetRaw,
        uint256 autoReleaseTime,
        uint256 autoCancelTime
    ) internal pure returns (EscrowSettings memory s) {
        s = EscrowSettings({
            customResolver: customResolver,
            releaseAddress: releaseAddress,
            yieldPreset: YieldPreset(presetRaw % 2),
            autoReleaseTime: autoReleaseTime,
            autoCancelTime: autoCancelTime
        });
    }

    // ---- external wrappers so reverts can be compared ----

    function _callOracle(
        address token,
        address to,
        address from,
        uint256 amount,
        EscrowSettings memory settings,
        uint256 escrowFee,
        uint256 workflowId,
        address resolutionModule
    ) external view returns (CreateOpsReference.CreateResult memory) {
        return createOps.computeEscrowCreation(token, to, from, amount, settings, escrowFee, workflowId, resolutionModule);
    }

    function _callLogic(
        address token,
        address to,
        address from,
        uint256 amount,
        EscrowSettings memory settings,
        uint256 escrowFee,
        uint256 workflowId,
        address resolutionModule,
        bool mustBeContract,
        bool paused
    ) external view returns (EscrowCreationLogic.CreateResult memory) {
        return EscrowCreationLogic.computeEscrowCreation(
            token, to, from, amount, settings, escrowFee, workflowId, resolutionModule, address(this), mustBeContract, paused
        );
    }

    function _applyPolicy(bool mustBeContract, bool paused) internal {
        createOps.setResolverPolicy(mustBeContract);
        if (paused && !createOps.yieldDepositsPaused()) createOps.pauseYieldDeposits('test');
        if (!paused && createOps.yieldDepositsPaused()) createOps.resumeYieldDeposits();
    }

    function _assertCreationEq(
        CreateOpsReference.CreateResult memory a,
        EscrowCreationLogic.CreateResult memory b
    ) internal pure {
        assertEq(a.fee, b.fee, 'fee');
        assertEq(a.amountAfterFee, b.amountAfterFee, 'amountAfterFee');
        assertEq(a.resolver, b.resolver, 'resolver');
        assertEq(a.yieldEnabled, b.yieldEnabled, 'yieldEnabled');
        assertEq(a.shouldDepositYield, b.shouldDepositYield, 'shouldDepositYield');
    }

    function _cmp(
        address token,
        address to,
        address from,
        uint256 amount,
        EscrowSettings memory settings,
        uint256 escrowFee,
        uint256 workflowId,
        address resolutionModule,
        bool mustBeContract,
        bool paused
    ) internal {
        _applyPolicy(mustBeContract, paused);

        bool oRev;
        bool lRev;
        CreateOpsReference.CreateResult memory a;
        EscrowCreationLogic.CreateResult memory b;

        try this._callOracle(token, to, from, amount, settings, escrowFee, workflowId, resolutionModule) returns (
            CreateOpsReference.CreateResult memory r
        ) {
            a = r;
        } catch {
            oRev = true;
        }

        try this._callLogic(
            token, to, from, amount, settings, escrowFee, workflowId, resolutionModule, mustBeContract, paused
        ) returns (EscrowCreationLogic.CreateResult memory r) {
            b = r;
        } catch {
            lRev = true;
        }

        assertEq(oRev, lRev, 'revert classification mismatch');
        if (!oRev) _assertCreationEq(a, b);
    }

    // ---- fuzzed differential ----

    function testFuzz_equiv_creation(
        address token,
        address to,
        address from,
        uint256 amount,
        address customResolver,
        address releaseAddress,
        uint8 presetRaw,
        uint256 autoReleaseTime,
        uint256 autoCancelTime,
        uint256 escrowFee,
        uint256 workflowId,
        uint8 modulePick,
        bool mustBeContract,
        bool paused
    ) public {
        amount = bound(amount, 0, 1e30);
        escrowFee = bound(escrowFee, 0, 10_000);
        autoReleaseTime = bound(autoReleaseTime, 0, 2 * 365 days);
        autoCancelTime = bound(autoCancelTime, 0, 2 * 365 days);

        address resolutionModule;
        if (modulePick % 3 == 1) resolutionModule = address(0xBEEF); // non-contract
        else if (modulePick % 3 == 2) resolutionModule = address(module); // configurable module

        _cmp(
            token,
            to,
            from,
            amount,
            _settings(customResolver, releaseAddress, presetRaw, autoReleaseTime, autoCancelTime),
            escrowFee,
            workflowId,
            resolutionModule,
            mustBeContract,
            paused
        );
    }

    /// @dev Full policy matrix over a valid base configuration (success path).
    function test_policyMatrix_successPath() public {
        bool[2] memory musts = [false, true];
        bool[2] memory pauses = [false, true];
        uint8[2] memory presets = [uint8(0), uint8(1)];
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = 0; j < 2; j++) {
                for (uint256 k = 0; k < 2; k++) {
                    _cmp(
                        address(0x7011),
                        RECIPIENT,
                        SENDER,
                        1e18,
                        _settings(address(0), address(0), presets[k], 0, 0),
                        100,
                        17,
                        address(module),
                        musts[i],
                        pauses[j]
                    );
                }
            }
        }
    }

    /// @dev Resolver lookup branches: zero module, non-contract, reverting, malformed.
    function test_resolverLookupBranches() public {
        EscrowSettings memory s = _settings(address(0), address(0), 0, 0, 0);

        _cmp(address(0x7011), RECIPIENT, SENDER, 1e18, s, 100, 1, address(0), false, false);
        _cmp(address(0x7011), RECIPIENT, SENDER, 1e18, s, 100, 1, address(0xBEEF), false, false);

        module.setResolver(address(0xD15507));
        _cmp(address(0x7011), RECIPIENT, SENDER, 1e18, s, 100, 1, address(module), false, false);

        module.setRevertLookup(true);
        _cmp(address(0x7011), RECIPIENT, SENDER, 1e18, s, 100, 1, address(module), false, false);

        module.setRevertLookup(false);
        module.setShortReturn(true);
        _cmp(address(0x7011), RECIPIENT, SENDER, 1e18, s, 100, 1, address(module), false, false);
    }

    /// @dev resolverMustBeContract guard: customResolver EOA vs contract.
    function test_resolverMustBeContractGuard() public {
        // EOA resolver: reverts when policy requires a contract.
        _cmp(
            address(0x7011), RECIPIENT, SENDER, 1e18,
            _settings(address(0xE0A), address(0), 0, 0, 0), 100, 1, address(0), true, false
        );
        // EOA resolver allowed when policy does not require a contract.
        _cmp(
            address(0x7011), RECIPIENT, SENDER, 1e18,
            _settings(address(0xE0A), address(0), 0, 0, 0), 100, 1, address(0), false, false
        );
        // Contract resolver: allowed under both policies.
        _cmp(
            address(0x7011), RECIPIENT, SENDER, 1e18,
            _settings(contractResolver, address(0), 0, 0, 0), 100, 1, address(0), true, false
        );
        _cmp(
            address(0x7011), RECIPIENT, SENDER, 1e18,
            _settings(contractResolver, address(0), 0, 0, 0), 100, 1, address(0), false, false
        );
    }

    /// @dev Yield policy guard: paused vs not, preset OFF vs TO_SENDER.
    function test_yieldPauseGuard() public {
        // Preset ON, not paused → should attempt deposit.
        _cmp(
            address(0x7011), RECIPIENT, SENDER, 1e18,
            _settings(address(0), address(0), 1, 0, 0), 100, 1, address(0), false, false
        );
        // Preset ON, paused → no deposit.
        _cmp(
            address(0x7011), RECIPIENT, SENDER, 1e18,
            _settings(address(0), address(0), 1, 0, 0), 100, 1, address(0), false, true
        );
        // Preset OFF → no deposit regardless of pause.
        _cmp(
            address(0x7011), RECIPIENT, SENDER, 1e18,
            _settings(address(0), address(0), 0, 0, 0), 100, 1, address(0), false, true
        );
    }

    /// @dev Invalid input rejection (token/amount/recipient/auto-times).
    function test_invalidInputsRejection() public {
        // zero token
        _cmp(address(0), RECIPIENT, SENDER, 1e18, _settings(address(0), address(0), 0, 0, 0), 100, 1, address(0), false, false);
        // zero amount
        _cmp(address(0x7011), RECIPIENT, SENDER, 0, _settings(address(0), address(0), 0, 0, 0), 100, 1, address(0), false, false);
        // recipient == sender
        _cmp(address(0x7011), SENDER, SENDER, 1e18, _settings(address(0), address(0), 0, 0, 0), 100, 1, address(0), false, false);
        // recipient == releaseAddress
        _cmp(address(0x7011), RECIPIENT, SENDER, 1e18, _settings(address(0), RECIPIENT, 0, 0, 0), 100, 1, address(0), false, false);
        // both auto times set
        _cmp(
            address(0x7011), RECIPIENT, SENDER, 1e18,
            _settings(address(0), address(0), 0, block.timestamp + 1 days, block.timestamp + 2 days),
            100, 1, address(0), false, false
        );
        // auto time in the past
        _cmp(
            address(0x7011), RECIPIENT, SENDER, 1e18,
            _settings(address(0), address(0), 0, block.timestamp - 1, 0),
            100, 1, address(0), false, false
        );
    }
}
