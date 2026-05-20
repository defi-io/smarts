# frozen_string_literal: true

module Polymarket
  # UMA-adapter event timeline: questions getting initialized (new markets
  # registered for resolution), resolved (the oracle answered), or disputed
  # (someone challenged the proposed answer). Question metadata is joined
  # from gamma /markets?question_ids=... so the UI shows actual market text
  # rather than a 32-byte hash.
  class UmaActivity
    INIT_EVENT = "QuestionInitialized"
    RESOLVED_EVENT = "QuestionResolved"
    DISPUTED_EVENT = "QuestionFlagged"
    PER_EVENT_LIMIT = 30
    DISPLAY_LIMIT = 6

    Resolved = Struct.new(
      :question_id, :market_label, :slug, :condition_id,
      :settled_price, :payouts, :timestamp, :tx_hash, :block_number,
      keyword_init: true
    )

    Initialized = Struct.new(
      :question_id, :market_label, :slug, :condition_id,
      :creator, :reward, :proposal_bond,
      :timestamp, :tx_hash, :block_number,
      keyword_init: true
    )

    Disputed = Struct.new(
      :question_id, :market_label, :slug,
      :timestamp, :tx_hash, :block_number,
      keyword_init: true
    )

    TimelineEvent = Struct.new(
      :kind, :label, :question_id, :market_label, :slug, :condition_id,
      :payouts, :timestamp, :tx_hash, :block_number,
      keyword_init: true
    )

    def self.call(contract:)
      new(contract: contract).call
    end

    def initialize(contract:)
      @contract = contract
    end

    def call
      resolved = fetch(RESOLVED_EVENT)
      initialized = fetch(INIT_EVENT)
      disputed = fetch(DISPUTED_EVENT)

      question_index = build_question_index([ resolved, initialized, disputed ])

      resolved_events = resolved.events.first(DISPLAY_LIMIT).map { |event| build_resolved(event, question_index) }
      initialized_events = initialized.events.first(DISPLAY_LIMIT).map { |event| build_initialized(event, question_index) }
      disputed_events = disputed.events.first(DISPLAY_LIMIT).map { |event| build_disputed(event, question_index) }

      {
        ok: true,
        resolved: resolved_events,
        initialized: initialized_events,
        disputed: disputed_events,
        timeline: build_timeline(
          initialized: initialized_events,
          disputed: disputed_events,
          resolved: resolved_events
        ),
        errors: collect_errors(resolved: resolved, initialized: initialized, disputed: disputed),
        fetched_at: Time.current
      }
    end

    private

    def fetch(event_name)
      result = ContractEvents::RecentFetcher.call(
        contract: @contract,
        event_name: event_name,
        limit: PER_EVENT_LIMIT
      )

      Rails.logger.warn("[UmaActivity] #{event_name}: #{result.error}") unless result.success?
      result
    end

    def build_question_index(results)
      ids = results.flat_map do |result|
        next [] unless result.respond_to?(:events)

        result.events.map { |event| event.args.is_a?(Hash) ? question_id_from(event.args) : nil }
      end.compact.uniq.first(50)

      return {} if ids.empty?

      PolymarketClient.fetch_markets_by_question_ids(ids)
    rescue PolymarketClient::Error => e
      Rails.logger.warn("[UmaActivity] question lookup failed: #{e.message}")
      {}
    end

    def build_resolved(event, index)
      args = event.args || {}
      qid = question_id_from(args)
      meta = index[qid]

      Resolved.new(
        question_id: qid,
        market_label: meta&.dig(:question) || meta&.dig(:slug) || Polymarket::EventValues.truncate(qid),
        slug: meta&.dig(:slug),
        condition_id: meta&.dig(:condition_id),
        settled_price: int(args["settledPrice"]),
        payouts: Array(args["payouts"]).map { |n| int(n) },
        timestamp: event.timestamp,
        tx_hash: event.tx_hash,
        block_number: event.block_number
      )
    end

    def build_initialized(event, index)
      args = event.args || {}
      qid = question_id_from(args)
      meta = index[qid]

      Initialized.new(
        question_id: qid,
        market_label: meta&.dig(:question) || meta&.dig(:slug) || Polymarket::EventValues.truncate(qid),
        slug: meta&.dig(:slug),
        condition_id: meta&.dig(:condition_id),
        creator: args["creator"],
        reward: int(args["reward"]),
        proposal_bond: int(args["proposalBond"]),
        timestamp: event.timestamp,
        tx_hash: event.tx_hash,
        block_number: event.block_number
      )
    end

    def build_disputed(event, index)
      args = event.args || {}
      qid = question_id_from(args)
      meta = index[qid]

      Disputed.new(
        question_id: qid,
        market_label: meta&.dig(:question) || meta&.dig(:slug) || Polymarket::EventValues.truncate(qid),
        slug: meta&.dig(:slug),
        timestamp: event.timestamp,
        tx_hash: event.tx_hash,
        block_number: event.block_number
      )
    end

    def collect_errors(resolved:, initialized:, disputed:)
      [
        [ RESOLVED_EVENT, resolved.error ],
        [ INIT_EVENT, initialized.error ],
        [ DISPUTED_EVENT, disputed.error ]
      ].select { |(_, error)| error.present? }.to_h
    end

    def build_timeline(initialized:, disputed:, resolved:)
      events = []
      events.concat(initialized.map { |event| timeline_event(:initialized, "Question", event) })
      events.concat(disputed.map { |event| timeline_event(:disputed, "Dispute", event) })
      events.concat(resolved.map { |event| timeline_event(:resolved, "Settled", event) })

      events.sort_by { |event| parse_time(event.timestamp) || Time.at(0) }.reverse.first(DISPLAY_LIMIT * 2)
    end

    def timeline_event(kind, label, event)
      TimelineEvent.new(
        kind: kind,
        label: label,
        question_id: event.question_id,
        market_label: event.market_label,
        slug: event.slug,
        condition_id: event.respond_to?(:condition_id) ? event.condition_id : nil,
        payouts: event.respond_to?(:payouts) ? event.payouts : nil,
        timestamp: event.timestamp,
        tx_hash: event.tx_hash,
        block_number: event.block_number
      )
    end

    def parse_time(value)
      return value if value.is_a?(Time)

      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def question_id_from(args)
      Polymarket::EventValues.bytes32(args["questionID"] || args["questionId"])
    end

    def int(value)
      Polymarket::EventValues.integer(value)
    end
  end
end
