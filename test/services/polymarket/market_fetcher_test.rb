require "test_helper"

class Polymarket::MarketFetcherTest < ActiveSupport::TestCase
  CONDITION_ID = "0x" + ("12" * 32)

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "combines client metadata, resolution state, and derived position ids" do
    stub_class_method(PolymarketClient, :fetch_market_by_slug, ->(_slug) { market }) do
      stub_class_method(Polymarket::ResolutionReader, :call, ->(**) { resolution }) do
        stub_class_method(ChainReader::ConditionalTokensReader, :position_ids, ->(**) { [ 111, 222 ] }) do
          result = Polymarket::MarketFetcher.call(slug: "sample")

          assert_equal "Polymarket", result.protocol
          assert_equal CONDITION_ID, result.condition_id
          assert_equal :unresolved, result.state
          assert_equal [ "Yes", "No" ], result.outcomes.map(&:name)
          assert_equal [ 111, 222 ], result.outcomes.map(&:position_id)
          assert_equal "101", result.outcomes.first.token_id
        end
      end
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
        PolymarketClient::Token.new(outcome: "Yes", token_id: "101", price: BigDecimal("0.5")),
        PolymarketClient::Token.new(outcome: "No", token_id: "202", price: BigDecimal("0.5"))
      ],
      collateral_token: PolymarketClient::PUSD,
      active: true,
      closed: false,
      neg_risk: false
    )
  end

  def resolution
    Polymarket::ResolutionReader::Result.new(
      state: :unresolved,
      payouts: nil,
      payout_denominator: 0,
      outcome_slot_count: 2,
      block_number: 19_000_000
    )
  end
end
