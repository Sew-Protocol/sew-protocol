#!/bin/bash

# BaseScan Source Code Verification Helper
# Verifies contracts on Base Sepolia testnet
# Requires: BASESCAN_API_KEY environment variable

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Base Sepolia Source Code Verification Helper${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Check if API key is set
if [ -z "$BASESCAN_API_KEY" ]; then
  echo -e "${RED}❌ ERROR: BASESCAN_API_KEY not set${NC}"
  echo ""
  echo "To verify contracts, you need a BaseScan API key:"
  echo "1. Visit: https://basescan.org/apis"
  echo "2. Create new API key"
  echo "3. Set environment variable:"
  echo "   export BASESCAN_API_KEY='your_key_here'"
  echo ""
  exit 1
fi

echo -e "${GREEN}✅ BASESCAN_API_KEY is set${NC}"
echo ""

# List of contracts to verify
declare -A CONTRACTS=(
  [EscrowVault]="0x13b8b7572c72b46879662BFEA53851cBeD3bC47a"
  [GovGovernor]="0xa9d598AE5b185dd249A1E4b64c32f18f4500d2fA"
  [SewToken]="0x62BD47154D0b5Fe435F220E1294405040102b2ba"
  [TimelockController]="0xD62A6C62233357B6681F9410218FE53BA931fDD1"
  [DefaultReleaseStrategy]="0x7F8A089339bD1b58e7ccB53f8F4eD2f0AD0DF47b"
  [ModuleSnapshotRegistry]="0x353f5F9e0997585779a48CcBD1e6F7d525f14376"
  [YieldOps]="0x6f39a05f88D8d7416AC5ebdE03e0579B6B2EE76B"
  [DisputeOps]="0x5915E46643452f0f009AF64D44Dc376350977aDf"
  [SettlementOps]="0xE5e9AADb88462ee72D76E86Ba88C5c825BD6B5A0"
  [CreateOps]="0x4dba1d914D45f80dda5Ddab123EA766196034738"
  [BondCollector]="0xad4FB744919dd147478d3D8d1C547f7b8F112e35"
  [L2AddressRegistry]="0xAf1af27D2d0467fd3bAd71416bB0e20B9291F796"
  [EscrowGovernanceTimelock]="0xE22CA9643B71f8437afd237f78fDD83f88293033"
)

echo -e "${YELLOW}Available contracts to verify:${NC}"
count=0
for contract in "${!CONTRACTS[@]}"; do
  ((count++))
  echo "  $count. $contract - ${CONTRACTS[$contract]}"
done
echo ""

# If argument provided, verify that contract
if [ -n "$1" ]; then
  CONTRACT_NAME="$1"
  
  if [ -z "${CONTRACTS[$CONTRACT_NAME]}" ]; then
    echo -e "${RED}❌ Contract '$CONTRACT_NAME' not found${NC}"
    echo ""
    echo "Available contracts:"
    for contract in "${!CONTRACTS[@]}"; do
      echo "  - $contract"
    done
    exit 1
  fi
  
  ADDRESS="${CONTRACTS[$CONTRACT_NAME]}"
  echo -e "${BLUE}Verifying ${GREEN}$CONTRACT_NAME${BLUE} at ${GREEN}$ADDRESS${NC}"
  echo ""
  
  # For EscrowVault, use constructor args
  if [ "$CONTRACT_NAME" = "EscrowVault" ]; then
    echo "Running verification with constructor arguments..."
    pnpm hardhat verify --network baseSepolia \
      "$ADDRESS" \
      "0" \
      "0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC" \
      "0x6f39a05f88D8d7416AC5ebdE03e0579B6B2EE76B" \
      "0x5915E46643452f0f009AF64D44Dc376350977aDf" \
      "0x353f5F9e0997585779a48CcBD1e6F7d525f14376"
  else
    echo "Running verification (checking for constructor args in deployment artifact)..."
    # Try to extract from deployment artifact
    if [ -f "deployments/baseSepolia/${CONTRACT_NAME}.json" ]; then
      ARGS=$(jq '.args' "deployments/baseSepolia/${CONTRACT_NAME}.json" 2>/dev/null || echo "[]")
      
      if [ "$ARGS" != "[]" ] && [ "$ARGS" != "null" ]; then
        echo "Found constructor args in artifact"
        pnpm hardhat verify --network baseSepolia --constructor-args <(echo "module.exports = $ARGS;") "$ADDRESS"
      else
        echo "No constructor args found, verifying without args..."
        pnpm hardhat verify --network baseSepolia "$ADDRESS"
      fi
    else
      pnpm hardhat verify --network baseSepolia "$ADDRESS"
    fi
  fi
else
  echo -e "${YELLOW}Usage:${NC} ./scripts/verify-base-sepolia-source.sh <CONTRACT_NAME>"
  echo ""
  echo "Examples:"
  echo "  ./scripts/verify-base-sepolia-source.sh EscrowVault"
  echo "  ./scripts/verify-base-sepolia-source.sh SewToken"
  echo "  ./scripts/verify-base-sepolia-source.sh GovGovernor"
  echo ""
  echo "To verify all contracts, run them individually or use hardhat-etherscan directly."
fi
