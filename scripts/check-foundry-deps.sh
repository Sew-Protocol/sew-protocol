#!/usr/bin/env bash
# Ensure Foundry dependencies (forge-std, halmos-cheatcodes) are present in lib/.
#
# These libraries are not git submodules and are gitignored (lib/); they are
# vendored into the working tree by scripts/fetch-foundry-deps.sh so Foundry
# builds/tests can run. For first-time developers cloning from git, the missing
# libraries are fetched automatically here; set SEW_NO_FOUNDRY_AUTO_FETCH=1 to
# disable auto-fetching and fail with instructions instead.
set -euo pipefail

required=(
  lib/forge-std/src/Test.sol
  lib/halmos-cheatcodes/src/SymTest.sol
)

missing=0
for f in "${required[@]}"; do
  if [[ ! -f "$f" ]]; then
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  if [[ "${SEW_NO_FOUNDRY_AUTO_FETCH:-0}" == "1" ]]; then
    printf '%s\n' 'Missing required Foundry libraries.' >&2
    printf '%s\n' 'Fetch them with: scripts/fetch-foundry-deps.sh   (or: pnpm deps:foundry)' >&2
    exit 1
  fi
  printf '%s\n' 'Missing required Foundry libraries — fetching them now.' >&2
  printf '%s\n' '(Set SEW_NO_FOUNDRY_AUTO_FETCH=1 to disable auto-fetching.)' >&2
  scripts/fetch-foundry-deps.sh
fi

# Re-check after any fetch; it may have failed (e.g. no network).
for f in "${required[@]}"; do
  if [[ ! -f "$f" ]]; then
    printf '%s\n' "Still missing $f — the fetch likely failed (no network?)." >&2
    printf '%s\n' 'Fetch manually with: scripts/fetch-foundry-deps.sh   (or: pnpm deps:foundry)' >&2
    exit 1
  fi
done
