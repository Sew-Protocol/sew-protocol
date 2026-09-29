#!/usr/bin/env bash
# Fetch Foundry dependencies (forge-std, halmos-cheatcodes) into lib/.
#
# These libraries are NOT git submodules and are gitignored (lib/); they are
# vendored into the working tree by this script so Foundry builds/tests can run.
# CI invokes this script before compiling; developers can run it once after
# cloning, or rely on scripts/check-foundry-deps.sh to prompt when they are
# missing.
#
# Idempotent: skips a dependency if it is already present.
set -euo pipefail

FORGE_STD_COMMIT="e3386f2f9cc5ebf16ec5370869d5a49cdb85a0cb"        # v1.14.0
HALMOS_CHEATCODES_COMMIT="6da4e692c357ba6d641a2e677a28298cac9f76ab" # main HEAD

fetch() {
  local dir="$1" url="$2" sha="$3" marker="$4"
  if [[ -f "$dir/$marker" ]]; then
    printf '%s already present (%s).\n' "$dir" "$dir/$marker"
    return
  fi
  printf 'Fetching %s @ %s into %s ...\n' "$url" "$sha" "$dir"
  rm -rf "$dir"
  git clone --quiet --no-checkout "$url" "$dir"
  git -C "$dir" checkout --quiet "$sha"
  rm -rf "$dir/.git"
}

fetch lib/forge-std "https://github.com/foundry-rs/forge-std" \
  "$FORGE_STD_COMMIT" "src/Test.sol"

fetch lib/halmos-cheatcodes "https://github.com/a16z/halmos-cheatcodes" \
  "$HALMOS_CHEATCODES_COMMIT" "src/SymTest.sol"
