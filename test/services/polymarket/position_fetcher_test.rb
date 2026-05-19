require "test_helper"

class Polymarket::PositionFetcherTest < ActiveSupport::TestCase
  CONDITION_ID = "0x" + ("12" * 32)
  OWNER = "0x000000000000000000000000000000000000beef"

  test "returns balances and redeemable flags per outcome" do
    stub_class_method(PolymarketClient, :fetch_market_by_condition_id, ->(_cid) { market }) do
      stub_class_method(Polymarket::ResolutionReader, :call, ->(**) { resolution }) do
        stub_class_method(ChainReader::ConditionalTokensReader, :position_ids, ->(**) { [ 111, 222 ] }) do
          balances = ChainReader::ConditionalTokensReader::Balances.new(values: [ 1_000_000, 0 ], block_number: 99)
          stub_class_method(ChainReader::ConditionalTokensReader, :balances, ->(**) { balances }) do
            result = Polymarket::PositionFetcher.call(address: OWNER, condition_ids: [ CONDITION_ID ])

            assert_equal 1, result.size
            assert_equal "sample", result.first[:slug]
            assert_equal true, result.first[:outcomes].first[:redeemable]
            assert_equal false, result.first[:outcomes].second[:redeemable]
          end
        end
      end
    end
  end

  test "caps requested markets" do
    ids = 11.times.map { |i| "0x" + i.to_s(16).rjust(64, "0") }

    assert_raises(ArgumentError) do
      Polymarket::PositionFetcher.call(address: OWNER, condition_ids: ids)
    end
  end

  private

  def market
    PolymarketClient::Market.new(
      condition_id: CONDITION_ID,
      slug: "sample",
      question: "Sample?",
      outcomes: [ "Yes", "No" ],
      clob_token_ids: [ "101", "202" ],
      tokens: [
        PolymarketClient::Token.new(outcome: "Yes", token_id: "101"),
        PolymarketClient::Token.new(outcome: "No", token_id: "202")
      ],
      collateral_token: PolymarketClient::PUSD
    )
  end

  def resolution
    Polymarket::ResolutionReader::Result.new(
      state: :resolved,
      payouts: [ 1, 0 ],
      payout_denominator: 1,
      outcome_slot_count: 2,
      block_number: 100
    )
  end
end
