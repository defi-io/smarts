class GovernanceTimelineRefreshJob < ApplicationJob
  queue_as :default

  # Time window during which we treat a contract's governance timeline as
  # already-fresh — additional show requests skip re-enqueueing this job and
  # serve cached DB rows instantly.
  FRESHNESS_TTL = 30.minutes

  def self.freshness_key(contract)
    "governance_fresh:#{contract.id}"
  end

  def self.fresh?(contract)
    Rails.cache.read(freshness_key(contract)).present?
  end

  def perform(contract_id)
    contract = Contract.find_by(id: contract_id)
    return unless contract

    result = GovernanceEvents::TimelineFetcher.call(contract: contract)

    # Mark fresh even on partial failure — TimelineFetcher already advances
    # the scan cursor, and we don't want hot retry loops on rate-limit errors.
    Rails.cache.write(self.class.freshness_key(contract), Time.current, expires_in: FRESHNESS_TTL)

    # Triggers a Turbo morph refresh on every open show page subscribed via
    # `turbo_stream_from @contract` — picks up newly fetched events without a
    # manual reload. Matches the pattern in EnrichContractAiJob.
    Turbo::StreamsChannel.broadcast_refresh_to(contract)

    result
  end
end
