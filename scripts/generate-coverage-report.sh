#!/bin/bash
# Generate coverage report with fallback to summary when forge coverage fails
# This script attempts forge coverage but falls back to the coverage summary
# if compilation fails due to stack too deep errors.

set -e

REPORT_FILE="${1:-report}"

echo "Attempting to generate coverage report..."
echo ""

# Try forge coverage with --ir-minimum first
if forge coverage --report summary --ir-minimum --allow-failure > "$REPORT_FILE" 2>&1; then
    echo "✓ Coverage report generated successfully: $REPORT_FILE"
    exit 0
fi

# If that fails, check if it's a stack too deep error
if grep -q "too deep in the stack\|Stack too deep" "$REPORT_FILE" 2>/dev/null; then
    echo "⚠️  Forge coverage failed due to stack too deep errors"
    echo "   This is a known limitation with complex contracts requiring viaIR"
    echo ""
    echo "Generating coverage summary report instead..."
    echo ""
    
    # Generate summary report
    bash scripts/coverage-summary.sh > "$REPORT_FILE" 2>&1
    
    echo ""
    echo "✓ Coverage summary report generated: $REPORT_FILE"
    echo ""
    echo "Note: This report contains estimated coverage based on test analysis."
    echo "      See docs/more/status/COVERAGE_REPORTING_STATUS.md for details."
    exit 0
else
    echo "✗ Coverage generation failed with unexpected error"
    echo "   See $REPORT_FILE for details"
    exit 1
fi
