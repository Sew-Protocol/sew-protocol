#!/bin/bash
set -e

# Backup decentralized-resolution-module if it exists
if [ -d "contracts/decentralized-resolution-module" ]; then
  mkdir -p /tmp/hd_backup
  cp -r contracts/decentralized-resolution-module /tmp/hd_backup/
  rm -rf contracts/decentralized-resolution-module
  CONTRACT_BACKUP=true
else
  CONTRACT_BACKUP=false
fi

# Backup test files that import DR module
if [ -d "test/foundry/decentralized-resolution-module" ]; then
  mkdir -p /tmp/hd_backup/test_foundry
  cp -r test/foundry/decentralized-resolution-module /tmp/hd_backup/test_foundry/
  rm -rf test/foundry/decentralized-resolution-module
  TEST_BACKUP=true
else
  TEST_BACKUP=false
fi

# List of core test files that import DR module
DR_DEPENDENT_TESTS=(
  "test/foundry/core/BondCollectorHardening.t.sol"
  "test/foundry/core/Phase1RefactorRiskTests.t.sol"
  "test/foundry/core/ReentrancyProtection.t.sol"
  "test/foundry/core/AppealWindowEnforcement.t.sol"
  "test/foundry/core/ResolverIncentiveModuleComprehensive.t.sol"
  "test/foundry/core/PaymentBoundsChecking.t.sol"
  "test/foundry/migrated/ResolverIncentiveModule.test.t.sol"
  "test/foundry/migrated/DecentralizedResolutionModule.test.t.sol"
  "test/foundry/governance/AccessControlEdgeCases.t.sol"
  "test/foundry/governance/ModuleSwapPath.test.t.sol"
  "test/foundry/testnet/Phase3DRStagedBaseSepoliaFork.t.sol"
)

# Backup core tests that import DR
mkdir -p /tmp/hd_backup/test_core_dr_dependent
for test_file in "${DR_DEPENDENT_TESTS[@]}"; do
  if [ -f "$test_file" ]; then
    mkdir -p "/tmp/hd_backup/test_core_dr_dependent/$(dirname $test_file)"
    cp "$test_file" "/tmp/hd_backup/test_core_dr_dependent/$test_file"
    rm "$test_file"
  fi
done

# Run the build
forge build

# Restore contracts if we backed up
if [ "$CONTRACT_BACKUP" = true ]; then
  mv /tmp/hd_backup/decentralized-resolution-module contracts/
fi

# Restore tests if we backed up
if [ "$TEST_BACKUP" = true ]; then
  mv /tmp/hd_backup/test_foundry/decentralized-resolution-module test/foundry/
fi

# Restore core tests that depend on DR
for test_file in "${DR_DEPENDENT_TESTS[@]}"; do
  if [ -f "/tmp/hd_backup/test_core_dr_dependent/$test_file" ]; then
    mkdir -p "$(dirname $test_file)"
    mv "/tmp/hd_backup/test_core_dr_dependent/$test_file" "$test_file"
  fi
done

# Cleanup
rm -rf /tmp/hd_backup 2>/dev/null || true
