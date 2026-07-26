// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { EscrowVault } from "../contracts/core/EscrowVault.sol";
import { EscrowViewContract } from "../contracts/core/EscrowViewContract.sol";
import { DefaultResolutionModule } from "../contracts/core/modules/DefaultResolutionModule.sol";
import { YieldOps } from "../contracts/ops/YieldOps.sol";
import { DisputeOps } from "../contracts/ops/DisputeOps.sol";
import { ModuleSnapshotRegistry } from "../contracts/core/ModuleSnapshotRegistry.sol";

/**
 * @title DifferentialSetup
 * @notice Forge script to deploy the SEW protocol stack for differential testing.
 *
 * Deploys:
 *   1. MockERC20 token
 *   2. YieldOps, DisputeOps (ops infrastructure)
 *   3. ModuleSnapshotRegistry
 *   4. EscrowVault
 *   5. EscrowViewContract (oracle)
 *   6. DefaultResolutionModule
 *
 * Exports addresses to differential-setup.json for AnvilRunner.
 */
contract DifferentialSetup is Script {
    // Well-known Anvil accounts
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant BUYER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant RESOLVER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    // Fee configuration
    uint256 constant ESCROW_FEE_BPS = 100; // 1%

    MockERC20 token;
    YieldOps yieldOps;
    DisputeOps disputeOps;
    ModuleSnapshotRegistry moduleRegistry;
    EscrowVault vault;
    EscrowViewContract oracle;
    DefaultResolutionModule drModule;

    function run() public {
        vm.startBroadcast();

        // Deploy MockERC20
        token = new MockERC20("Test USDC", "USDC");
        console.log("Deployed MockERC20:", address(token));

        // Mint tokens to buyer (10M * 1e18)
        token.mint(BUYER, 10_000_000 * 1e18);
        console.log("Minted tokens to BUYER");

        // Deploy YieldOps (this handles yield delegation)
        yieldOps = new YieldOps(DEPLOYER);
        console.log("Deployed YieldOps:", address(yieldOps));

        // Deploy DisputeOps (this handles dispute operations)
        disputeOps = new DisputeOps(DEPLOYER);
        console.log("Deployed DisputeOps:", address(disputeOps));

        // Deploy ModuleSnapshotRegistry
        moduleRegistry = new ModuleSnapshotRegistry(DEPLOYER);
        console.log("Deployed ModuleSnapshotRegistry:", address(moduleRegistry));

        // Deploy EscrowVault with all required dependencies
        vault = new EscrowVault(
            ESCROW_FEE_BPS,           // escrowFeeBps
            DEPLOYER,                 // feeAddress
            address(yieldOps),        // yieldOpsAddress
            address(disputeOps),      // disputeOpsAddress
            address(moduleRegistry)   // moduleManagementAddress
        );
        console.log("Deployed EscrowVault:", address(vault));

        // Deploy EscrowViewContract (oracle)
        oracle = new EscrowViewContract(address(vault));
        console.log("Deployed EscrowViewContract:", address(oracle));

        // Deploy DefaultResolutionModule
        drModule = new DefaultResolutionModule(DEPLOYER, RESOLVER);
        console.log("Deployed DefaultResolutionModule:", address(drModule));

        vm.stopBroadcast();

        // Export addresses to JSON
        _exportAddresses();
    }

    function _exportAddresses() internal {
        // Build JSON string manually to ensure all addresses are captured
        string memory json = string(abi.encodePacked(
            '{"token":"', addressToString(address(token)), '",',
            '"vault":"', addressToString(address(vault)), '",',
            '"oracle":"', addressToString(address(oracle)), '",',
            '"drModule":"', addressToString(address(drModule)), '",',
            '"yieldOps":"', addressToString(address(yieldOps)), '",',
            '"disputeOps":"', addressToString(address(disputeOps)), '",',
            '"moduleRegistry":"', addressToString(address(moduleRegistry)), '",',
            '"deployer":"', addressToString(DEPLOYER), '",',
            '"buyer":"', addressToString(BUYER), '",',
            '"resolver":"', addressToString(RESOLVER), '"}'
        ));

        // Write to differential-setup.json
        string memory outputDir = vm.projectRoot();
        vm.writeJson(json, string.concat(outputDir, "/differential-setup.json"));
        console.log("Exported addresses to differential-setup.json");
    }

    function addressToString(address addr) internal pure returns (string memory) {
        bytes memory addrBytes = abi.encodePacked(addr);
        bytes memory result = new bytes(42);
        result[0] = '0';
        result[1] = 'x';
        for (uint256 i = 0; i < 20; i++) {
            uint8 value = uint8(addrBytes[i]);
            uint8 hi = value >> 4;
            uint8 lo = value & 0x0f;
            result[2 + i * 2] = bytes1(hi < 10 ? hi + 0x30 : hi + 0x57);
            result[3 + i * 2] = bytes1(lo < 10 ? lo + 0x30 : lo + 0x57);
        }
        return string(result);
    }
}
