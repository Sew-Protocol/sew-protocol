#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Contract size gate for the BondLedger custody extraction (PRF_REVIEW_COMMIT).
#
# Freezes the review facade and primitive at their committed sizes so the
# facade is not silently grown toward the EIP-170 limit (24576 bytes) ahead of
# deployment. Any growth requires explicit approval.
#
# Frozen reference sizes (PRF_REVIEW_COMMIT 4959328, verified 2026-07-31):
#   BondLedger (primitive)             5194 bytes
#   ResolverIncentiveModuleV2BondLedger 24300 bytes (facade, 276 B headroom)
#
# Gate policy:
#   - BondLedger must not exceed its frozen size + SAFETY_MARGIN (explicit
#     approval required to grow the primitive).
#   - The facade must stay below EIP-170 (24576) AND below its frozen size;
#     effectively frozen until deployment. A warning is emitted above
#     FACADE_WARN_HEADROOM.
#
# Usage:
#   scripts/check-bondledger-size.sh [--json]
set -euo pipefail

EIP170=24576
SAFETY_MARGIN=500
FACADE_WARN_HEADROOM=1024

BONDLEDGER_FROZEN=5194
FACADE_FROZEN=24300

BONDLEDGER_SPEC="contracts/shared/BondLedger.sol:BondLedger"
FACADE_SPEC="contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2BondLedger.sol:ResolverIncentiveModuleV2BondLedger"

runtime_bytes() {
  local spec="$1"
  forge inspect "$spec" deployedBytecode 2>/dev/null \
    | python3 -c "import sys; b=sys.stdin.read().strip(); print((len(b)-2)//2)"
}

fail=0
warning=""

bondledger=$(runtime_bytes "$BONDLEDGER_SPEC")
facade=$(runtime_bytes "$FACADE_SPEC")

# BondLedger primitive: frozen size + explicit-approval margin
if [ "$bondledger" -gt $((BONDLEDGER_FROZEN + SAFETY_MARGIN)) ]; then
  echo "FAIL: BondLedger grew to ${bondledger} B (frozen ${BONDLEDGER_FROZEN} B + ${SAFETY_MARGIN} B margin). Requires explicit approval." >&2
  fail=1
fi

# Facade: effectively frozen below EIP-170
if [ "$facade" -ge "$EIP170" ]; then
  echo "FAIL: facade is ${facade} B, at/over EIP-170 limit ${EIP170} B." >&2
  fail=1
elif [ "$facade" -gt "$FACADE_FROZEN" ]; then
  echo "FAIL: facade grew to ${facade} B (frozen ${FACADE_FROZEN} B). Requires explicit approval." >&2
  fail=1
elif [ $((EIP170 - facade)) -lt "$FACADE_WARN_HEADROOM" ]; then
  warning="facade headroom only $((EIP170 - facade)) B under EIP-170; treat as frozen."
fi

if [ -n "$warning" ]; then
  echo "WARN: $warning" >&2
fi

if [ "${1:-}" = "--json" ]; then
  PASS_BOOL=$([ $fail -eq 0 ] && echo "True" || echo "False")
  python3 -c "
import json,sys
print(json.dumps({
  'bondledger': {'bytes': $bondledger, 'frozen': $BONDLEDGER_FROZEN, 'ok': $bondledger <= $((BONDLEDGER_FROZEN + SAFETY_MARGIN))},
  'facade': {'bytes': $facade, 'frozen': $FACADE_FROZEN, 'eip170_limit': $EIP170, 'ok': $facade <= $FACADE_FROZEN},
  'pass': $PASS_BOOL,
  'warning': $(python3 -c "import json; print(json.dumps('$warning'))")
}, indent=2))
"
fi

exit $fail
