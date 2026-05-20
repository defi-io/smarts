require "test_helper"

class GetPolymarketMarketToolTest < ActiveSupport::TestCase
  test "returns stable Polymarket market payload" do
    result_struct = Polymarket::MarketFetcher::Result.new(
      protocol: "Polymarket",
      slug: "sample",
      condition_id: "0x" + ("12" * 32),
      question: "Sample?",
      outcomes: [
        Polymarket::MarketFetcher::Outcome.new(
          name: "Yes", token_id: "101", position_id: 111, price: BigDecimal("0.62"),
          mid_price: BigDecimal("0.61"), best_bid: BigDecimal("0.60"), best_ask: BigDecimal("0.62")
        ),
        Polymarket::MarketFetcher::Outcome.new(name: "No", token_id: "202", position_id: 222, price: BigDecimal("0.38"))
      ],
      neg_risk: false,
      state: :unresolved,
      payouts: nil,
      payout_denominator: 0,
      end_date: "2026-12-31T00:00:00Z",
      volume_num: BigDecimal("123.45"),
      active: true,
      closed: false,
      accepting_orders: true,
      enable_order_book: true,
      collateral_token: PolymarketClient::PUSD,
      block_number: 19_000_000,
      fetched_at: Time.utc(2026, 5, 19, 12, 0, 0)
    )

    stub_class_method(Polymarket::MarketFetcher, :call, ->(**) { result_struct }) do
      payload = GetPolymarketMarketTool.payload(slug: "sample")

      assert_equal "Polymarket", payload[:protocol]
      assert_equal "sample", payload[:slug]
      assert_equal "0.62", payload[:outcomes].first[:price]
      assert_equal "0.61", payload[:outcomes].first[:mid_price]
      assert_equal "0.6", payload[:outcomes].first[:best_bid]
      assert_equal "0.62", payload[:outcomes].first[:best_ask]
      assert_equal "2026-05-19T12:00:00Z", payload[:fetched_at]
      assert_match(/polymarket\.com/, payload[:links][:polymarket_url])
    end
  end

  test "returns error when no market identifier is provided" do
    assert_equal "provide slug or condition_id", GetPolymarketMarketTool.payload[:error]
  end
end
