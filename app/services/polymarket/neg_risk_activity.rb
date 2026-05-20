# frozen_string_literal: true

module Polymarket
  # NegRiskAdapter is the multi-outcome resolver. Each market is decomposed
  # into binary subquestions (will-X-win?, will-Y-win?, …) that each get
  # resolved independently. The exact event names differ from the standard
  # UMA adapter, so we probe a known set and surface whichever ones the
  # contract's ABI actually exposes. Misses degrade gracefully — they just
  # don't appear in the panel.
  class NegRiskActivity
    PROBE_EVENTS = %w[
      MarketPrepared
      MarketResolved
      QuestionPrepared
      QuestionResolved
      OutcomeReported
    ].freeze
    PER_EVENT_LIMIT = 20
    DISPLAY_LIMIT = 6

    Activity = Struct.new(
      :event_name, :market_id, :question_id, :outcome_index, :outcome,
      :payouts, :timestamp, :tx_hash, :block_number, :raw_args,
      keyword_init: true
    )

    def self.call(contract:)
      new(contract: contract).call
    end

    def initialize(contract:)
      @contract = contract
    end

    def call
      results = PROBE_EVENTS.map do |name|
        [ name, ContractEvents::RecentFetcher.call(contract: @contract, event_name: name, limit: PER_EVENT_LIMIT) ]
      end

      activity_groups = {}
      results.each do |name, result|
        next unless result.success?
        next if result.events.empty?

        activity_groups[name] = result.events.first(DISPLAY_LIMIT).map { |event| build_activity(name, event) }
      end

      missing = results.reject { |_, r| r.success? }.map { |name, r| [ name, r.error ] }.to_h

      {
        ok: true,
        groups: activity_groups,
        empty: activity_groups.empty?,
        unavailable_events: missing,
        fetched_at: Time.current
      }
    end

    private

    def build_activity(event_name, event)
      args = event.args || {}
      Activity.new(
        event_name: event_name,
        market_id: Polymarket::EventValues.bytes32(args["marketId"] || args["marketID"]),
        question_id: Polymarket::EventValues.bytes32(args["questionId"] || args["questionID"]),
        outcome_index: Polymarket::EventValues.integer(args["outcomeIndex"]),
        outcome: Polymarket::EventValues.boolean(args["outcome"]),
        payouts: Array(args["payouts"]).map { |n| Polymarket::EventValues.integer(n) },
        timestamp: event.timestamp,
        tx_hash: event.tx_hash,
        block_number: event.block_number,
        raw_args: args
      )
    end

  end
end
