# frozen_string_literal: true

module Polymarket
  class ResolutionReader
    CONDITIONAL_TOKENS = "0x4d97dcd97ec945f40cf65f87097ace5ea0476045"

    Result = Struct.new(:state, :payouts, :payout_denominator, :outcome_slot_count, :block_number, keyword_init: true)

    class << self
      def call(chain:, condition_id:, ct_address: CONDITIONAL_TOKENS)
        state = ChainReader::ConditionalTokensReader.read_state(
          chain: chain,
          ct_address: ct_address,
          condition_id: condition_id
        )

        Result.new(
          state: state.state,
          payouts: state.payout_numerators,
          payout_denominator: state.payout_denominator,
          outcome_slot_count: state.outcome_slot_count,
          block_number: state.block_number
        )
      end
    end
  end
end
