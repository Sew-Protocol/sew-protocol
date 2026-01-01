.PHONY: install test hh forge deploy export

install:
	pnpm i

test:
	pnpm test

hh:
	pnpm test:hardhat

forge:
	pnpm test:foundry

deploy:
	pnpm deploy --network $(NETWORK)

export:
	pnpm export --network $(NETWORK)
