// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import "contracts/core/EscrowVault.sol";
import "contracts/core/ModuleSnapshotRegistry.sol";
import "contracts/admin/EscrowGovernanceTimelock.sol";
import "contracts/core/modules/DefaultResolutionModule.sol";
import "contracts/ops/DisputeOps.sol";
import "contracts/ops/SettlementOps.sol";
import "contracts/ops/CreateOps.sol";
import "contracts/core/BondCollector.sol";
import "contracts/mocks/ERC20Mock.sol";
import "contracts/libraries/SettingsValidationLibrary.sol";
import "contracts/interfaces/IYieldGenerationModule.sol";
import "contracts/interfaces/IYieldDistributionModule.sol";

contract BadYieldOps {
    // Provide a stub so tests can "register" the escrow contract.
    function registerEscrowContract(address) external {}

    // IMPORTANT: selector is based only on name + input types, not return type.
    // Returning a single uint256 makes the return data 32 bytes, which is malformed for YieldOps.YieldResult.
    function handleYield(
        IYieldGenerationModule,
        IYieldDistributionModule,
        uint256,
        address,
        uint256,
        uint256,
        address,
        bytes memory
    ) external returns (uint256) {
        return 0;
    }
    
    // Implement ERC165 to pass EscrowVault constructor validation
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7; // ERC165 interface ID
    }
}

contract YieldWithdrawalNonBlockingTest is Test {
    EscrowVault vault;
    ModuleSnapshotRegistry moduleManagement;
    EscrowGovernanceTimelock adminContract;
    DefaultResolutionModule rm;
    DisputeOps disputeOps;
    SettlementOps settlementOps;
    CreateOps createOps;
    BondCollector bondCollector;
    BadYieldOps badYieldOps;
    ERC20Mock token;

    address feeAddress = address(0xFEE);
    address resolver = address(0xBEEF);
    address sender = address(0x1001);
    address recipient = address(0x1002);

    uint256 constant ESCROW_FEE = 100; // 1%
    uint256 constant AMOUNT = 10 ether;

    function setUp() public {
        disputeOps = new DisputeOps(address(this));
        settlementOps = new SettlementOps(address(this));
        createOps = new CreateOps(address(this));
        bondCollector = new BondCollector(address(this));
        moduleManagement = new ModuleSnapshotRegistry(address(this));
        adminContract = new EscrowGovernanceTimelock(address(this));

        badYieldOps = new BadYieldOps();
        vault = new EscrowVault(ESCROW_FEE, feeAddress, address(badYieldOps), address(disputeOps), address(moduleManagement));
        moduleManagement.registerEscrowContract(address(vault));

        // Register escrow contract with ops contracts
        disputeOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));
        badYieldOps.registerEscrowContract(address(vault));

        // Wire ops
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(this));
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), address(adminContract));
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));

        // Activate a resolution module so escrow creation succeeds.
        rm = new DefaultResolutionModule(address(this), resolver);
        vault.grantRole(vault.ROLE_TIMELOCK(), address(this));
        adminContract.grantRole(adminContract.ROLE_TIMELOCK(), address(this));
        adminContract.queueResolutionModule(address(vault), address(rm));
        vm.warp(block.timestamp + 7 days + 1);
        adminContract.activateResolutionModule(address(vault));

        token = new ERC20Mock("Test", "TST", address(this), 1e24);
        token.transfer(sender, 1000 ether);
    }

    function test_yield_withdrawal_malformed_return_does_not_brick_release() public {
        vm.prank(sender);
        token.approve(address(vault), AMOUNT);

        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        // Enable yield so BaseEscrow attempts the yield path.
        settings.yieldPreset = YieldPreset.TO_SENDER;

        vm.prank(sender);
        uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);

        // Should not revert even though yieldOps returns malformed data.
        vm.prank(sender);
        vault.release(wid);
    }
}

