#!/bin/bash
# Coverage Summary Script
# Computes measured project-contract coverage from coverage/lcov.filtered.info
# (produced by scripts/filter-coverage.js from `forge coverage --report lcov`).

set -euo pipefail

lcov="${COVERAGE_LCONV:-coverage/lcov.filtered.info}"

if [ ! -f "$lcov" ]; then
  echo "error: $lcov not found. Run \`forge coverage --report lcov\` then scripts/filter-coverage.js first." >&2
  exit 2
fi

awk '
  function pct(l,h){ return h>0 ? (h*100.0)/l : 0 }
  /^SF:/{files++}
  /^LF:/{lf += substr($0,4)}
  /^LH:/{lh += substr($0,4)}
  /^FNF:/{fnf += substr($0,5)}
  /^FNH:/{fnh += substr($0,5)}
  /^BRF:/{brf += substr($0,5)}
  /^BRH:/{brh += substr($0,5)}
  END{
    printf "Files:      %d\n", files
    printf "Lines:      %d/%d (%.1f%%)\n", lh, lf, pct(lf,lh)
    printf "Functions:  %d/%d (%.1f%%)\n", fnh, fnf, pct(fnf,fnh)
    printf "Branches:   %d/%d (%.1f%%)\n", brh, brf, pct(brf,brh)
  }
' "$lcov"

echo ""
echo "Source: $lcov"
