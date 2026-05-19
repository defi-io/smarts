require "test_helper"

class Polymarket::ResolutionReaderTest < ActiveSupport::TestCase
  test "wraps ConditionalTokensReader state in Polymarket result shape" do
    ctf_state = ChainReader::ConditionalTokensReader::State.new(
      state: :resolved,
      outcome_slot_count: 2,
      payout_denominator: 1,
      payout_numerators: [ 1, 0 ],
      block_number: 66
    )

    stub_class_method(ChainReader::ConditionalTokensReader, :read_state, ->(**) { ctf_state }) do
      result = Polymarket::ResolutionReader.call(chain: chains(:polygon), condition_id: "0x" + ("12" * 32))

      assert_equal :resolved, result.state
      assert_equal [ 1, 0 ], result.payouts
      assert_equal 1, result.payout_denominator
      assert_equal 66, result.block_number
    end
  end
end
