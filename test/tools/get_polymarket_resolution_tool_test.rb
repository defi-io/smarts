require "test_helper"

class GetPolymarketResolutionToolTest < ActiveSupport::TestCase
  test "returns on-chain resolution audit payload" do
    result_struct = Polymarket::MarketFetcher::Result.new(
      protocol: "Polymarket",
      slug: "sample",
      condition_id: "0x" + ("12" * 32),
      question: "Sample?",
      outcomes: [
        Polymarket::MarketFetcher::Outcome.new(name: "Yes", token_id: "101", position_id: 111),
        Polymarket::MarketFetcher::Outcome.new(name: "No", token_id: "202", position_id: 222)
      ],
      neg_risk: false,
      state: :resolved,
      payouts: [ 1, 0 ],
      payout_denominator: 1,
      end_date: "2026-12-31T00:00:00Z",
      volume_num: BigDecimal("123.45"),
      active: false,
      closed: true,
      accepting_orders: false,
      enable_order_book: true,
      collateral_token: PolymarketClient::PUSD,
      block_number: 19_000_000,
      fetched_at: Time.utc(2026, 5, 20, 12, 0, 0)
    )

    stub_class_method(Polymarket::MarketFetcher, :call, ->(**) { result_struct }) do
      payload = GetPolymarketResolutionTool.payload(slug: "sample")

      assert_equal :resolved, payload[:resolution][:state]
      assert_equal [ 1, 0 ], payload[:resolution][:payouts]
      assert_equal true, payload[:outcomes].first[:winning]
      assert_equal false, payload[:outcomes].second[:winning]
      assert_equal "consistent", payload[:audit][:status]
      assert_equal "Polymarket Conditional Tokens", payload[:sources][:chain][:contract]
      assert_equal "Polymarket Gamma API", payload[:sources][:api][:provider]
      assert_match(/payoutDenominator/, payload[:sources][:chain][:fields][:state])
      assert_match(/conditional-tokens/, payload[:links][:conditional_tokens_contract])
    end
  end

  test "flags api closed while chain remains unresolved" do
    result_struct = Polymarket::MarketFetcher::Result.new(
      protocol: "Polymarket",
      slug: "sample",
      condition_id: "0x" + ("12" * 32),
      question: "Sample?",
      outcomes: [],
      neg_risk: false,
      state: :unresolved,
      payouts: nil,
      payout_denominator: 0,
      active: false,
      closed: true,
      accepting_orders: false,
      enable_order_book: true,
      block_number: 19_000_000,
      fetched_at: Time.utc(2026, 5, 20, 12, 0, 0)
    )

    stub_class_method(Polymarket::MarketFetcher, :call, ->(**) { result_struct }) do
      payload = GetPolymarketResolutionTool.payload(condition_id: "0x" + ("12" * 32))

      assert_equal "api_closed_chain_unresolved", payload[:audit][:status]
    end
  end

  test "returns error when no market identifier is provided" do
    assert_equal "provide slug or condition_id", GetPolymarketResolutionTool.payload[:error]
  end
end
