import { Address, Bytes } from "@graphprotocol/graph-ts"
import { 
  ProposalCreated, 
  ProposalCanceled, 
  ProposalExecuted, 
  ProposalQueued,
  VoteCast 
} from "../generated/GovGovernor/GovGovernor"
import { Proposal, Vote } from "../generated/schema"

export function handleProposalCreated(event: ProposalCreated): void {
  let proposal = new Proposal(event.params.proposalId.toString())
  proposal.proposer = event.params.proposer
  proposal.targets = event.params.targets.map<Bytes>((a: Address) => a)
  proposal.values = event.params.values
  proposal.signatures = event.params.signatures
  proposal.calldatas = event.params.calldatas
  proposal.startBlock = event.params.voteStart
  proposal.endBlock = event.params.voteEnd
  proposal.description = event.params.description
  proposal.state = "PENDING"
  proposal.createdAt = event.block.timestamp
  proposal.save()
}

export function handleProposalCanceled(event: ProposalCanceled): void {
  let proposal = Proposal.load(event.params.proposalId.toString())
  if (!proposal) return
  
  proposal.state = "CANCELED"
  proposal.canceledAt = event.block.timestamp
  proposal.save()
}

export function handleProposalExecuted(event: ProposalExecuted): void {
  let proposal = Proposal.load(event.params.proposalId.toString())
  if (!proposal) return
  
  proposal.state = "EXECUTED"
  proposal.executedAt = event.block.timestamp
  proposal.save()
}

export function handleProposalQueued(event: ProposalQueued): void {
  let proposal = Proposal.load(event.params.proposalId.toString())
  if (!proposal) return
  
  proposal.state = "QUEUED"
  proposal.save()
}

export function handleVoteCast(event: VoteCast): void {
  let voteId = event.params.proposalId.toString() + "-" + event.params.voter.toHexString()
  let vote = new Vote(voteId)
  vote.proposal = event.params.proposalId.toString()
  vote.voter = event.params.voter
  vote.support = event.params.support
  vote.votes = event.params.weight
  vote.reason = event.params.reason
  vote.timestamp = event.block.timestamp
  vote.transactionHash = event.transaction.hash
  vote.save()
}
