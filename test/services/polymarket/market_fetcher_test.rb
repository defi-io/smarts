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

  test "adds live CLOB prices for active orderbook markets" do
    market = self.market
    market.enable_order_book = true
    live_prices = {
      "101" => { mid_price: BigDecimal("0.61"), best_bid: BigDecimal("0.60"), best_ask: BigDecimal("0.62") },
      "202" => { mid_price: BigDecimal("0.39"), best_bid: BigDecimal("0.38"), best_ask: BigDecimal("0.40") }
    }

    stub_class_method(PolymarketClient, :fetch_market_by_slug, ->(_slug) { market }) do
      stub_class_method(PolymarketClient, :fetch_live_prices, ->(_token_ids) { live_prices }) do
        stub_class_method(Polymarket::ResolutionReader, :call, ->(**) { resolution }) do
          stub_class_method(ChainReader::ConditionalTokensReader, :position_ids, ->(**) { [ 111, 222 ] }) do
            result = Polymarket::MarketFetcher.call(slug: "sample")

            assert_equal BigDecimal("0.61"), result.outcomes.first.mid_price
            assert_equal BigDecimal("0.60"), result.outcomes.first.best_bid
            assert_equal BigDecimal("0.62"), result.outcomes.first.best_ask
          end
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
