import { Transfer, DelegateChanged, DelegateVotesChanged } from "../generated/SewToken/SewToken"
import { TokenHolder, TokenTransfer, DelegateChange, DelegateVotes } from "../generated/schema"

export function handleTransfer(event: Transfer): void {
  let senderId = event.params.from.toHexString()
  let recipientId = event.params.to.toHexString()
  
  let sender = TokenHolder.load(senderId)
  if (!sender) {
    sender = new TokenHolder(senderId)
    sender.balance = event.params.value
  } else {
    sender.balance = sender.balance.minus(event.params.value)
  }
  sender.save()

  let recipient = TokenHolder.load(recipientId)
  if (!recipient) {
    recipient = new TokenHolder(recipientId)
    recipient.balance = event.params.value
  } else {
    recipient.balance = recipient.balance.plus(event.params.value)
  }
  recipient.save()

  let transfer = new TokenTransfer(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  transfer.from = event.params.from
  transfer.to = event.params.to
  transfer.value = event.params.value
  transfer.timestamp = event.block.timestamp
  transfer.blockNumber = event.block.number
  transfer.transactionHash = event.transaction.hash
  transfer.save()
}

export function handleDelegateChanged(event: DelegateChanged): void {
  let holderId = event.params.delegator.toHexString()
  let holder = TokenHolder.load(holderId)
  if (holder) {
    holder.delegate = event.params.toDelegate
    holder.save()
  }

  let change = new DelegateChange(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  change.delegator = event.params.delegator
  change.fromDelegate = event.params.fromDelegate
  change.toDelegate = event.params.toDelegate
  change.timestamp = event.block.timestamp
  change.transactionHash = event.transaction.hash
  change.save()
}

export function handleDelegateVotesChanged(event: DelegateVotesChanged): void {
  let votesId = event.params.delegate.toHexString()
  let votes = new DelegateVotes(votesId)
  votes.votes = event.params.newVotes
  votes.checkpoint = event.block.number
  votes.save()
}
