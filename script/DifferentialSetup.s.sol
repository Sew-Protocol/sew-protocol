// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import 'forge-std/Script.sol';
import '../contracts/core/EscrowVault.sol';
import '../contracts/mocks/ERC20Mock.sol';
import '../contracts/ops/YieldOps.sol';
import '../contracts/ops/DisputeOps.sol';
import '../contracts/core/ModuleSnapshotRegistry.sol';
import '../contracts/ops/CreateOps.sol';
import '../contracts/ops/SettlementOps.sol';
import '../contracts/core/BondCollector.sol';
import '../contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol';
import './DifferentialOracle.sol';

/**
 * @title DifferentialSetup
 * @notice Forge script that deploys the full EscrowVault stack plus a
 *         DifferentialOracle and writes all addresses to JSON so the Python
 *         harness can pick them up.
 *
 * Usage (against running Anvil instance on default port 8545):
 *   forge script script/DifferentialSetup.s.sol \
 *     --rpc-url http://127.0.0.1:8545 \
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
 *     --broadcast
 *
 * Anvil well-known accounts used:
 *   Account 0 (deployer/operator): 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
 *   Account 1 (buyer):             0x70997970C51812dc3A010C7d01b50e0d17dc79C8
 *   Account 2 (resolver):          0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
 *
 * Output file: differential-setup.json (in repo root; gitignored)
 */
contract DifferentialSetup is Script {
    // Anvil well-known addresses
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant BUYER    = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant RESOLVER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    // Fee: 1% (100 bps) — matches test suite
    uint256 constant FEE_BPS = 100;

    // Buyer starting balance: 100,000 tokens (18 decimals)
    uint256 constant BUYER_BALANCE = 100_000e18;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy test ERC20
        ERC20Mock token = new ERC20Mock('SEW Test Token', 'SEWT', DEPLOYER, 1_000_000e18);

        // 2. Deploy ops contracts and module registry
        YieldOps             yieldOps     = new YieldOps(DEPLOYER);
        DisputeOps           disputeOps   = new DisputeOps(DEPLOYER);
        ModuleSnapshotRegistry mm          = new ModuleSnapshotRegistry(DEPLOYER);
        CreateOps            createOps    = new CreateOps(DEPLOYER);
        SettlementOps        settlementOps = new SettlementOps(DEPLOYER);
        BondCollector        bondCollector = new BondCollector(DEPLOYER);

        // 3. Deploy resolution module (deployer = admin)
        DecentralizedResolutionModule drModule =
            new DecentralizedResolutionModule(DEPLOYER);

        // 4. Deploy EscrowVault
        EscrowVault vault = new EscrowVault(
            FEE_BPS,
            DEPLOYER,          // fee recipient = deployer for tests
            address(yieldOps),
            address(disputeOps),
            address(mm)
        );

        // 5. Register vault with all ops contracts
        yieldOps.registerEscrowContract(address(vault));
        disputeOps.registerEscrowContract(address(vault));
        mm.registerEscrowContract(address(vault));
        createOps.registerEscrowContract(address(vault));
        settlementOps.registerEscrowContract(address(vault));
        bondCollector.registerEscrowContract(address(vault));

        // 6. Wire ops contracts into vault
        vault.grantRole(vault.ROLE_ADMIN_CONTRACT(), DEPLOYER);
        vault.setCreateOps(address(createOps));
        vault.setSettlementOps(address(settlementOps));
        vault.setBondCollector(address(bondCollector));
        vault.setResolutionModule(address(drModule));

        // 7. Bootstrap DR module resolver set
        //    DEPLOYER has DEFAULT_ADMIN_ROLE; self-grant ROLE_TIMELOCK to use governance.
        //    DEPLOYER becomes the senior resolver (enables calling appointResolver).
        //    RESOLVER (account 2) is the L0 resolver for differential tests.
        bytes32 drTimelock = drModule.ROLE_TIMELOCK();
        drModule.grantRole(drTimelock, DEPLOYER);
        drModule.registerEscrowContract(address(vault));
        drModule.appointSeniorResolver(DEPLOYER, 'Senior', 'Differential test senior resolver');
        drModule.appointResolver(RESOLVER, 'Resolver', 'Differential test L0 resolver');

        // 8. Deploy oracle (read-only helper for the harness)
        DifferentialOracle oracle = new DifferentialOracle(address(vault), address(drModule));

        // 9. Fund buyer
        token.transfer(BUYER, BUYER_BALANCE);

        vm.stopBroadcast();

        // 10. Write addresses to JSON for Python harness
        string memory json = 'setup';
        vm.serializeAddress(json, 'vault',         address(vault));
        vm.serializeAddress(json, 'drModule',      address(drModule));
        vm.serializeAddress(json, 'oracle',        address(oracle));
        vm.serializeAddress(json, 'token',         address(token));
        vm.serializeAddress(json, 'createOps',     address(createOps));
        vm.serializeAddress(json, 'settlementOps', address(settlementOps));
        vm.serializeAddress(json, 'bondCollector', address(bondCollector));
        vm.serializeAddress(json, 'deployer',      DEPLOYER);
        vm.serializeAddress(json, 'buyer',         BUYER);
        vm.serializeAddress(json, 'resolver',      RESOLVER);
        vm.serializeUint(   json, 'feeBps',        FEE_BPS);
        string memory output = vm.serializeUint(json, 'buyerBalance', BUYER_BALANCE);
        vm.writeJson(output, './differential-setup.json');
    }
}
