#!/bin/bash
# Generate coverage report with fallback to summary when forge coverage fails
# This script attempts forge coverage but falls back to the coverage summary
# if compilation fails due to stack too deep errors.

REPORT_FILE="${1:-report}"
TEMP_FILE="${REPORT_FILE}.tmp"

echo "Attempting to generate coverage report..."
echo ""

# Function to check if error is stack too deep
is_stack_too_deep_error() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    # Check for various stack too deep error patterns
    grep -qi "too deep.*stack\|Stack too deep\|Variable.*too deep\|too deep in the stack" "$file" 2>/dev/null
}

# Try forge coverage with --ir-minimum first
echo "Trying forge coverage with --ir-minimum..."
if forge coverage --report summary --ir-minimum --allow-failure > "$TEMP_FILE" 2>&1; then
    mv "$TEMP_FILE" "$REPORT_FILE"
    echo "✓ Coverage report generated successfully: $REPORT_FILE"
    exit 0
fi

# Check if temp file exists and if it's a stack too deep error
if [ -f "$TEMP_FILE" ] && is_stack_too_deep_error "$TEMP_FILE"; then
    echo "⚠️  Forge coverage failed due to stack too deep errors"
    echo "   This is a known limitation with complex contracts requiring viaIR"
    echo ""
    echo "Generating coverage summary report instead..."
    echo ""
    
    # Generate summary report
    if bash scripts/coverage-summary.sh > "$REPORT_FILE" 2>&1; then
        rm -f "$TEMP_FILE"
        echo ""
        echo "✓ Coverage summary report generated: $REPORT_FILE"
        echo ""
        echo "Note: This report contains estimated coverage based on test analysis."
        echo "      See docs/more/status/COVERAGE_REPORTING_STATUS.md for details."
        exit 0
    else
        echo "✗ Failed to generate coverage summary report"
        rm -f "$TEMP_FILE"
        exit 1
    fi
else
    # Unexpected error - show it and exit
    if [ -f "$TEMP_FILE" ]; then
        mv "$TEMP_FILE" "$REPORT_FILE"
        echo "✗ Coverage generation failed with unexpected error"
        echo "   See $REPORT_FILE for details"
        echo ""
        echo "Last 20 lines of error output:"
        tail -20 "$REPORT_FILE"
    else
        echo "✗ Coverage generation failed - no error output captured"
        echo "   Try running: forge coverage --report summary --ir-minimum --allow-failure"
    fi
    exit 1
fi
