class WarmupGovernanceCacheJob < ApplicationJob
  queue_as :default

  # Periodic: walks every curated slug and enqueues a per-contract refresh.
  # Each per-contract job is a cheap no-op when the freshness cache is still
  # warm, so running every 30 minutes is safe — only the contracts that
  # actually need a re-scan pay the Etherscan cost.
  def perform
    ContractSlugs::MAP.each_value do |(chain_slug, address)|
      chain = Chain.find_by(slug: chain_slug)
      next unless chain

      contract = Contract.find_by(chain: chain, address: address.downcase)
      next unless contract

      GovernanceTimelineRefreshJob.perform_later(contract.id)
    end
  end
end
