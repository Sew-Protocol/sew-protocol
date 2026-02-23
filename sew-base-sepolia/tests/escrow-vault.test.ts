import {
  assert,
  describe,
  test,
  clearStore,
  beforeAll,
  afterAll
} from "matchstick-as/assembly/index"
import { BigInt, Address, Bytes } from "@graphprotocol/graph-ts"
import { AppealBondProtocolFeeBpsUpdated } from "../generated/schema"
import { AppealBondProtocolFeeBpsUpdated as AppealBondProtocolFeeBpsUpdatedEvent } from "../generated/EscrowVault/EscrowVault"
import { handleAppealBondProtocolFeeBpsUpdated } from "../src/escrow-vault"
import { createAppealBondProtocolFeeBpsUpdatedEvent } from "./escrow-vault-utils"

// Tests structure (matchstick-as >=0.5.0)
// https://thegraph.com/docs/en/subgraphs/developing/creating/unit-testing-framework/#tests-structure

describe("Describe entity assertions", () => {
  beforeAll(() => {
    let oldFeeBps = BigInt.fromI32(234)
    let newFeeBps = BigInt.fromI32(234)
    let newAppealBondProtocolFeeBpsUpdatedEvent =
      createAppealBondProtocolFeeBpsUpdatedEvent(oldFeeBps, newFeeBps)
    handleAppealBondProtocolFeeBpsUpdated(
      newAppealBondProtocolFeeBpsUpdatedEvent
    )
  })

  afterAll(() => {
    clearStore()
  })

  // For more test scenarios, see:
  // https://thegraph.com/docs/en/subgraphs/developing/creating/unit-testing-framework/#write-a-unit-test

  test("AppealBondProtocolFeeBpsUpdated created and stored", () => {
    assert.entityCount("AppealBondProtocolFeeBpsUpdated", 1)

    // 0xa16081f360e3847006db660bae1c6d1b2e17ec2a is the default address used in newMockEvent() function
    assert.fieldEquals(
      "AppealBondProtocolFeeBpsUpdated",
      "0xa16081f360e3847006db660bae1c6d1b2e17ec2a-1",
      "oldFeeBps",
      "234"
    )
    assert.fieldEquals(
      "AppealBondProtocolFeeBpsUpdated",
      "0xa16081f360e3847006db660bae1c6d1b2e17ec2a-1",
      "newFeeBps",
      "234"
    )

    // More assert options:
    // https://thegraph.com/docs/en/subgraphs/developing/creating/unit-testing-framework/#asserts
  })
})
