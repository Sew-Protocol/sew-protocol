#!/usr/bin/env bash
# Fetch Foundry dependencies (forge-std, halmos-cheatcodes) into lib/.
#
# These libraries are NOT git submodules and are gitignored (lib/); they are
# vendored into the working tree by this script so Foundry builds/tests can run.
# CI invokes this script before compiling; developers can run it once after
# cloning, or rely on scripts/check-foundry-deps.sh to prompt when they are
# missing.
#
# Idempotent: skips a dependency whose files are present AND whose recorded
# commit (.foundry-commit) matches the pinned commit. If the pinned commit was
# bumped, the dependency is re-fetched at the new commit so existing checkouts
# stay in sync with CI.
set -euo pipefail

FORGE_STD_COMMIT="f3dae6e6ee381f25eb6a246f7da9b85c91a68219"        # v1.17.0
HALMOS_CHEATCODES_COMMIT="6da4e692c357ba6d641a2e677a28298cac9f76ab" # main HEAD

fetch() {
  local dir="$1" url="$2" sha="$3" marker="$4"
  local commit_marker="$dir/.foundry-commit"
  if [[ -f "$dir/$marker" && -f "$commit_marker" && "$(cat "$commit_marker")" == "$sha" ]]; then
    printf '%s up to date (%s).\n' "$dir" "$sha"
    return
  fi
  printf 'Fetching %s @ %s into %s ...\n' "$url" "$sha" "$dir"
  rm -rf "$dir"
  git clone --quiet --no-checkout "$url" "$dir"
  git -C "$dir" checkout --quiet "$sha"
  rm -rf "$dir/.git"
  printf '%s' "$sha" > "$commit_marker"
}

fetch lib/forge-std "https://github.com/foundry-rs/forge-std" \
  "$FORGE_STD_COMMIT" "src/Test.sol"

fetch lib/halmos-cheatcodes "https://github.com/a16z/halmos-cheatcodes" \
  "$HALMOS_CHEATCODES_COMMIT" "src/SymTest.sol"
