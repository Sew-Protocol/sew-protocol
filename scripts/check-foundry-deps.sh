#!/usr/bin/env bash
set -euo pipefail

missing=0
if [[ ! -f lib/forge-std/src/Test.sol ]]; then
  printf '%s\n' 'Missing lib/forge-std. Initialize the submodule with: git submodule update --init --recursive'
  printf '%s\n' 'If using a JJ workspace, ensure lib/forge-std points to a checked-out forge-std directory.'
  missing=1
fi

if [[ ! -f lib/halmos-cheatcodes/src/SymTest.sol ]]; then
  printf '%s\n' 'Missing lib/halmos-cheatcodes. Copy or link the Halmos cheatcodes source into lib/halmos-cheatcodes.'
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  printf '%s\n' 'Foundry tests/build cannot run until the required libraries are present.' >&2
  exit 1
fi
