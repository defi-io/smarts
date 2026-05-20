# frozen_string_literal: true

module Polymarket
  # Reads ConditionalTokens events: new conditions being created, resolutions
  # landing, and redeemers cashing out payout shares. Shapes them into a small
  # payload the CTF role partial can render directly.
  class CtfActivity
    PREP_EVENT = "ConditionPreparation"
    RES_EVENT = "ConditionResolution"
    REDEEM_EVENT = "PayoutRedemption"
    PER_EVENT_LIMIT = 25
    DISPLAY_LIMIT = 6
    USDC_DECIMALS = 6

    Resolution = Struct.new(
      :condition_id, :question_id, :oracle, :outcome_slot_count,
      :payouts, :market_label, :slug, :timestamp, :tx_hash, :block_number,
      keyword_init: true
    )

    Preparation = Struct.new(
      :condition_id, :question_id, :oracle, :outcome_slot_count,
      :market_label, :slug, :timestamp, :tx_hash, :block_number,
      keyword_init: true
    )

    Redemption = Struct.new(
      :redeemer, :condition_id, :payout, :timestamp, :tx_hash, :block_number,
      keyword_init: true
    )

    def self.call(contract:)
      new(contract: contract).call
    end

    def initialize(contract:)
      @contract = contract
    end

    def call
      resolutions = fetch(RES_EVENT)
      preparations = fetch(PREP_EVENT)
      redemptions = fetch(REDEEM_EVENT)

      condition_index = build_condition_index([ resolutions, preparations, redemptions ])

      {
        ok: true,
        resolutions: resolutions.events.first(DISPLAY_LIMIT).map { |event| build_resolution(event, condition_index) },
        preparations: preparations.events.first(DISPLAY_LIMIT).map { |event| build_preparation(event, condition_index) },
        redemptions: redemptions.events.first(DISPLAY_LIMIT).map { |event| build_redemption(event) },
        errors: collect_errors(resolutions: resolutions, preparations: preparations, redemptions: redemptions),
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

      return result if result.success?

      Rails.logger.warn("[CtfActivity] #{event_name} fetch failed: #{result.error}")
      result
    end

    def build_condition_index(result_groups)
      ids = result_groups.flat_map do |result|
        next [] unless result.respond_to?(:events)

        result.events.map { |event| event.args.is_a?(Hash) ? condition_id_from(event.args) : nil }
      end.compact.uniq.first(50)

      return {} if ids.empty?

      PolymarketClient.fetch_markets_by_condition_ids(ids)
    rescue PolymarketClient::Error => e
      Rails.logger.warn("[CtfActivity] condition lookup failed: #{e.message}")
      {}
    end

    def build_resolution(event, condition_index)
      args = event.args || {}
      cid = condition_id_from(args)
      meta = condition_index[cid]

      Resolution.new(
        condition_id: cid,
        question_id: question_id_from(args),
        oracle: args["oracle"],
        outcome_slot_count: int(args["outcomeSlotCount"]),
        payouts: Array(args["payoutNumerators"]).map { |n| int(n) },
        market_label: meta&.dig(:question) || meta&.dig(:slug) || Polymarket::EventValues.truncate(cid),
        slug: meta&.dig(:slug),
        timestamp: event.timestamp,
        tx_hash: event.tx_hash,
        block_number: event.block_number
      )
    end

    def build_preparation(event, condition_index)
      args = event.args || {}
      cid = condition_id_from(args)
      meta = condition_index[cid]

      Preparation.new(
        condition_id: cid,
        question_id: question_id_from(args),
        oracle: args["oracle"],
        outcome_slot_count: int(args["outcomeSlotCount"]),
        market_label: meta&.dig(:question) || meta&.dig(:slug) || Polymarket::EventValues.truncate(cid),
        slug: meta&.dig(:slug),
        timestamp: event.timestamp,
        tx_hash: event.tx_hash,
        block_number: event.block_number
      )
    end

    def build_redemption(event)
      args = event.args || {}
      payout = int(args["payout"])
      Redemption.new(
        redeemer: args["redeemer"],
        condition_id: condition_id_from(args),
        payout: payout && (BigDecimal(payout) / BigDecimal(10**USDC_DECIMALS)),
        timestamp: event.timestamp,
        tx_hash: event.tx_hash,
        block_number: event.block_number
      )
    end

    def collect_errors(resolutions:, preparations:, redemptions:)
      [
        [ RES_EVENT, resolutions.error ],
        [ PREP_EVENT, preparations.error ],
        [ REDEEM_EVENT, redemptions.error ]
      ].select { |(_, error)| error.present? }.to_h
    end

    def condition_id_from(args)
      Polymarket::EventValues.bytes32(args["conditionId"] || args["conditionID"])
    end

    def question_id_from(args)
      Polymarket::EventValues.bytes32(args["questionId"] || args["questionID"])
    end

    def int(value)
      Polymarket::EventValues.integer(value)
    end
  end
end
