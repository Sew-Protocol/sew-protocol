.PHONY: install compile test hh forge forge-invariants halmos-smoke formal-smoke coverage coverage-report format lint typecheck clean size size-check verify deploy deploy-local export help

# Default target
help:
	@echo "Available targets:"
	@echo "  install       - Install dependencies"
	@echo "  compile       - Compile contracts (Hardhat + Foundry)"
	@echo "  test          - Run all tests (Hardhat + Foundry)"
	@echo "  hh            - Run Hardhat tests only"
	@echo "  forge         - Run Foundry tests only"
	@echo "  forge-invariants - Run Foundry invariant suite only"
	@echo "  halmos-smoke  - Run Halmos bounded symbolic smoke check"
	@echo "  formal-smoke  - Run Foundry invariants + Halmos smoke"
	@echo "  coverage      - Generate test coverage report"
	@echo "  coverage-report - Generate coverage report (with fallback)"
	@echo "  format        - Format code with Prettier"
	@echo "  lint          - Run ESLint"
	@echo "  typecheck     - Type check TypeScript files"
	@echo "  clean         - Clean build artifacts"
	@echo "  size          - Print contract sizes"
	@echo "  size-check    - Compile and check contract sizes"
	@echo "  verify        - Verify contracts on block explorer"
	@echo "  deploy        - Deploy contracts (requires NETWORK=name)"
	@echo "  deploy-local  - Deploy to local Hardhat network"
	@echo "  export        - Export deployment ledger (requires NETWORK=name)"

# Dependencies
install:
	pnpm i

# Compilation
compile:
	pnpm compile

# Testing
test:
	pnpm test

hh:
	pnpm test:hardhat

forge:
	pnpm test:foundry

forge-invariants:
	pnpm test:foundry:invariants

halmos-smoke:
	pnpm test:halmos:smoke

formal-smoke:
	pnpm test:formal:smoke

coverage:
	pnpm coverage

coverage-report:
	bash scripts/generate-coverage-report.sh report

# Code Quality
format:
	pnpm format

lint:
	pnpm lint

typecheck:
	pnpm typecheck

# Cleanup
clean:
	rm -rf cache cache-foundry out artifacts dist typechain-types coverage deploy-ledger .hardhat

# Contract Size
size:
	pnpm size

size-check:
	pnpm size:check

# Verification
verify:
	pnpm verify

# Deployment
deploy:
	@if [ -z "$(NETWORK)" ]; then \
		echo "Error: NETWORK variable is required. Usage: make deploy NETWORK=baseSepolia"; \
		exit 1; \
	fi
	pnpm deploy --network $(NETWORK)

deploy-local:
	pnpm deploy:local

export:
	@if [ -z "$(NETWORK)" ]; then \
		echo "Error: NETWORK variable is required. Usage: make export NETWORK=baseSepolia"; \
		exit 1; \
	fi
	pnpm export --network $(NETWORK)
