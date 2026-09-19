#!/usr/bin/env bash
# usage: ./run_core.sh <match-path-or-contract args...>
SKIPS="--skip TraceEquivalence --skip TraceRegression --skip DifferentialSetup --skip OpsCoverage --skip Ops --skip AppealBondDistribution --skip AppealBondRecording --skip BondRounding --skip DirectResolutionConfigSelection --skip DisputeCapacityExhaustion --skip DRv3CrossModuleInvariants --skip EscalationDepthHistogram --skip IncentiveModuleExploit --skip IncentiveModuleIntegration --skip BondBehaviourCorrection --skip BondLedgerDifferential"
forge test $SKIPS "$@"
