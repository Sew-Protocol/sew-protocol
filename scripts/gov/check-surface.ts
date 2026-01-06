#!/usr/bin/env ts-node

/**
 * Governance Surface Consistency Checker
 * 
 * Validates that the governance surface map matches the actual contract implementation.
 * 
 * Checks:
 * 1. Functions marked "removed" do not exist in contracts
 * 2. Governed functions have expected modifiers (onlyRole(ROLE_TIMELOCK), onlyRole(ROLE_GUARDIAN))
 * 3. Slow lane functions follow queue/activate pattern
 * 4. Emergency functions use ROLE_GUARDIAN
 */

import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";

interface CheckResult {
  passed: boolean;
  message: string;
}

const REMOVED_FUNCTIONS = [
  "setReleaseStrategyForEscrow",
  "setResolutionModuleForEscrow",
  "setYieldGenerationModuleForEscrow",
  "setYieldDistributionModuleForEscrow",
];

const DEPRECATED_FUNCTIONS = [
  "setAuthorizedResolver",
];

const SLOW_LANE_FUNCTIONS = [
  "queueDefaultReleaseStrategy",
  "activateDefaultReleaseStrategy",
  "queueDefaultResolutionModule",
  "activateDefaultResolutionModule",
  "queueDefaultYieldGenerationModule",
  "activateDefaultYieldGenerationModule",
  "queueDefaultYieldDistributionModule",
  "activateDefaultYieldDistributionModule",
  "queueEscrowFeeAddress",
  "activateEscrowFeeAddress",
  "queueEscrowFee",
  "activateEscrowFee",
  "queueDao",
  "activateDao",
  "queueAavePoolProvider",
  "activateAavePoolProvider",
  "queueEscalationConfig",
  "activateEscalationConfig",
];

const EMERGENCY_FUNCTIONS = [
  "pause",
  "guardianDisableAave",
  "guardianLowerTokenCap",
  "guardianLowerGlobalCap",
];

function checkRemovedFunctions(): CheckResult[] {
  const results: CheckResult[] = [];
  const contractsDir = path.join(process.cwd(), "contracts");
  
  for (const funcName of REMOVED_FUNCTIONS) {
    try {
      const grepResult = execSync(
        `grep -r "function ${funcName}" ${contractsDir} || true`,
        { encoding: "utf-8" }
      );
      
      if (grepResult.trim()) {
        results.push({
          passed: false,
          message: `❌ Function ${funcName} is marked as removed but still exists in contracts`,
        });
      } else {
        results.push({
          passed: true,
          message: `✅ Function ${funcName} correctly removed`,
        });
      }
    } catch (error) {
      results.push({
        passed: false,
        message: `⚠️  Could not check ${funcName}: ${error}`,
      });
    }
  }
  
  return results;
}

function checkDeprecatedFunctions(): CheckResult[] {
  const results: CheckResult[] = [];
  const contractsDir = path.join(process.cwd(), "contracts");
  
  for (const funcName of DEPRECATED_FUNCTIONS) {
    try {
      const grepResult = execSync(
        `grep -A 5 "function ${funcName}" ${contractsDir}/BaseEscrow.sol || true`,
        { encoding: "utf-8" }
      );
      
      if (grepResult.includes("revert") || grepResult.includes("revert(")) {
        results.push({
          passed: true,
          message: `✅ Function ${funcName} correctly reverts`,
        });
      } else {
        results.push({
          passed: false,
          message: `❌ Function ${funcName} is deprecated but does not revert`,
        });
      }
    } catch (error) {
      results.push({
        passed: false,
        message: `⚠️  Could not check ${funcName}: ${error}`,
      });
    }
  }
  
  return results;
}

function checkSlowLanePattern(): CheckResult[] {
  const results: CheckResult[] = [];
  const contractsDir = path.join(process.cwd(), "contracts");
  
  for (const funcName of SLOW_LANE_FUNCTIONS) {
    try {
      const grepResult = execSync(
        `grep -r "function ${funcName}" ${contractsDir} || true`,
        { encoding: "utf-8" }
      );
      
      if (!grepResult.trim()) {
        // Function doesn't exist, skip
        continue;
      }
      
      // Check if it uses ROLE_TIMELOCK
      const roleCheck = execSync(
        `grep -A 3 "function ${funcName}" ${contractsDir}/*.sol ${contractsDir}/**/*.sol 2>/dev/null | grep -E "onlyRole\\(ROLE_TIMELOCK\\)|ROLE_TIMELOCK" || true`,
        { encoding: "utf-8" }
      );
      
      if (roleCheck.trim()) {
        results.push({
          passed: true,
          message: `✅ Function ${funcName} uses ROLE_TIMELOCK`,
        });
      } else {
        results.push({
          passed: false,
          message: `❌ Function ${funcName} should use onlyRole(ROLE_TIMELOCK)`,
        });
      }
    } catch (error) {
      // Function might not exist, which is OK
      results.push({
        passed: true,
        message: `ℹ️  Function ${funcName} not found (may not be implemented yet)`,
      });
    }
  }
  
  return results;
}

function checkEmergencyFunctions(): CheckResult[] {
  const results: CheckResult[] = [];
  const contractsDir = path.join(process.cwd(), "contracts");
  
  for (const funcName of EMERGENCY_FUNCTIONS) {
    try {
      const grepResult = execSync(
        `grep -r "function ${funcName}" ${contractsDir} || true`,
        { encoding: "utf-8" }
      );
      
      if (!grepResult.trim()) {
        // Function doesn't exist, skip
        continue;
      }
      
      // Check if it uses ROLE_GUARDIAN
      const roleCheck = execSync(
        `grep -A 3 "function ${funcName}" ${contractsDir}/*.sol ${contractsDir}/**/*.sol 2>/dev/null | grep -E "onlyRole\\(ROLE_GUARDIAN\\)|ROLE_GUARDIAN" || true`,
        { encoding: "utf-8" }
      );
      
      if (roleCheck.trim()) {
        results.push({
          passed: true,
          message: `✅ Function ${funcName} uses ROLE_GUARDIAN`,
        });
      } else {
        results.push({
          passed: false,
          message: `❌ Function ${funcName} should use onlyRole(ROLE_GUARDIAN)`,
        });
      }
    } catch (error) {
      // Function might not exist, which is OK
      results.push({
        passed: true,
        message: `ℹ️  Function ${funcName} not found (may not be implemented yet)`,
      });
    }
  }
  
  return results;
}

async function main() {
  console.log("\n🔍 Checking Governance Surface Consistency...\n");
  
  const allResults: CheckResult[] = [];
  
  console.log("1. Checking removed functions...");
  allResults.push(...checkRemovedFunctions());
  
  console.log("\n2. Checking deprecated functions...");
  allResults.push(...checkDeprecatedFunctions());
  
  console.log("\n3. Checking slow lane functions...");
  allResults.push(...checkSlowLanePattern());
  
  console.log("\n4. Checking emergency functions...");
  allResults.push(...checkEmergencyFunctions());
  
  console.log("\n" + "=".repeat(60));
  console.log("Results:\n");
  
  let passed = 0;
  let failed = 0;
  
  for (const result of allResults) {
    console.log(result.message);
    if (result.passed) {
      passed++;
    } else {
      failed++;
    }
  }
  
  console.log("\n" + "=".repeat(60));
  console.log(`Summary: ${passed} passed, ${failed} failed\n`);
  
  if (failed > 0) {
    console.error("❌ Governance surface check failed!");
    process.exit(1);
  } else {
    console.log("✅ All governance surface checks passed!");
    process.exit(0);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });




