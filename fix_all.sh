for file in test/foundry/core/{EscrowableERC20Coverage,FeeScenarioFlows,ReleaseEscrowEdgeCases,ReleaseFlexibility,VaultAccountingBug,WithdrawEscrow,YieldWithdrawalNonBlocking}.t.sol; do
    echo "Processing $file"
    # 1. Add import
    sed -i 's/import.*EscrowVault.sol";/import "..\/..\/..\/contracts\/core\/EscrowVault.sol";\nimport "..\/..\/..\/contracts\/modules\/DefaultReleaseStrategy.sol";/' $file
    # 2. Add state
    sed -i 's/EscrowVault public escrow;/EscrowVault public escrow;\n    DefaultReleaseStrategy public releaseStrategy;/' $file
    sed -i 's/EscrowVault public vault;/EscrowVault public vault;\n    DefaultReleaseStrategy public releaseStrategy;/' $file
    # 3. Add instantiation in setUp (handle different contract names)
    sed -i '/resolutionModule = new DefaultResolutionModule/a \        releaseStrategy = new DefaultReleaseStrategy();' $file
    # 4. Add queue/activate in setUp
    sed -i '/vm.warp(block.timestamp + 8 days);/a \        moduleManagement.activateModule(address(vault), BaseEscrow.ModuleType.RELEASE);' $file
    sed -i '/moduleManagement.registerEscrowContract/a \        moduleManagement.queueModule(address(vault), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));' $file
    sed -i '/moduleManagement.registerEscrowContract/a \        moduleManagement.queueModule(address(escrow), BaseEscrow.ModuleType.RELEASE, address(releaseStrategy));' $file
    sed -i '/vm.warp(block.timestamp + 8 days);/a \        moduleManagement.activateModule(address(escrow), BaseEscrow.ModuleType.RELEASE);' $file
done
