require "test_helper"

class Polymarket::ExchangeActivityTest < ActiveSupport::TestCase
  setup do
    @polygon = chains(:polygon)
    @contract = Contract.new(chain: @polygon, address: "0xe111180000d2663c0091e4f400237545b87b996b")
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "aggregates fills by market, labels them, and surfaces latest fills" do
    yes_token = "1"
    no_token = "2"
    events = [
      build_event(maker_asset: "0", taker_asset: yes_token, maker_amt: 100_000_000, taker_amt: 135_135_135, maker: "0xmaker1", taker: "0xtaker1"),
      build_event(maker_asset: yes_token, taker_asset: "0", maker_amt: 50_000_000, taker_amt: 37_500_000, maker: "0xmaker2", taker: "0xtaker2"),
      build_event(maker_asset: "0", taker_asset: no_token, maker_amt: 25_000_000, taker_amt: 100_000_000, maker: "0xmaker1", taker: "0xtaker3")
    ]
    token_index = {
      yes_token => PolymarketClient::TokenRef.new(token_id: yes_token, outcome: "Yes", slug: "btc-200k", question: "Will BTC top $200k?", condition_id: "0xabc"),
      no_token  => PolymarketClient::TokenRef.new(token_id: no_token,  outcome: "No",  slug: "btc-200k", question: "Will BTC top $200k?", condition_id: "0xabc")
    }

    with_stubs(success_result(events), token_index) do
      result = Polymarket::ExchangeActivity.call(contract: @contract)

      assert result[:ok]
      assert_equal 3, result[:fills_count]
      assert_equal BigDecimal("162.5"), result[:volume_usdc]
      assert_equal 3, result[:unique_takers]
      assert_equal 2, result[:unique_markets]
      assert_equal "Will BTC top $200k? · Yes", result[:latest_fills].first.market_label

      top = result[:top_markets].first
      assert_equal yes_token, top.token_id
      assert_equal 2, top.fills_count
      assert_equal BigDecimal("137.5"), top.volume_usdc
    end
  end

  test "labels unknown markets when the token index misses" do
    events = [
      build_event(maker_asset: "0", taker_asset: "999", maker_amt: 1_000_000, taker_amt: 2_000_000, maker: "0xm", taker: "0xt")
    ]

    with_stubs(success_result(events), {}) do
      result = Polymarket::ExchangeActivity.call(contract: @contract)

      assert_equal "Unknown market", result[:latest_fills].first.market_label
      assert_equal 1, result[:fills_count]
    end
  end

  test "drops fills where both legs are non-zero (token swaps, not USDC trades)" do
    events = [
      build_event(maker_asset: "5", taker_asset: "6", maker_amt: 100, taker_amt: 100, maker: "0xa", taker: "0xb")
    ]

    with_stubs(success_result(events), {}) do
      result = Polymarket::ExchangeActivity.call(contract: @contract)

      assert_equal 0, result[:fills_count]
      assert_empty result[:latest_fills]
    end
  end

  test "returns an error payload when the fetcher reports an error" do
    with_stubs(error_result("etherscan 502"), {}) do
      result = Polymarket::ExchangeActivity.call(contract: @contract)

      refute result[:ok]
      assert_equal "etherscan 502", result[:error]
    end
  end

  private

  def build_event(maker_asset:, taker_asset:, maker_amt:, taker_amt:, maker:, taker:, timestamp: 1.minute.ago.utc.iso8601)
    ContractEvents::RecentFetcher::Event.new(
      event: "OrderFilled",
      args: {
        "orderHash" => "0xhash",
        "maker" => maker,
        "taker" => taker,
        "makerAssetId" => maker_asset,
        "takerAssetId" => taker_asset,
        "makerAmountFilled" => maker_amt,
        "takerAmountFilled" => taker_amt,
        "fee" => 0
      },
      block_number: 70_000_000,
      tx_hash: "0xdeadbeef",
      log_index: 0,
      timestamp: timestamp
    )
  end

  def success_result(events)
    ContractEvents::RecentFetcher::Result.new(
      contract: @contract.address, chain: "polygon", event_filter: "OrderFilled",
      latest_block: 70_000_100, from_block: 69_995_100, count: events.size,
      events: events, error: nil
    )
  end

  def error_result(message)
    ContractEvents::RecentFetcher::Result.new(
      contract: @contract.address, chain: "polygon", event_filter: "OrderFilled",
      latest_block: nil, from_block: nil, count: 0, events: [], error: message
    )
  end

  def with_stubs(fetcher_result, token_index, &block)
    stub_class_method(ContractEvents::RecentFetcher, :call, ->(contract:, event_name:, limit:) { fetcher_result }) do
      stub_class_method(PolymarketClient, :fetch_token_id_index, ->(*) { token_index }, &block)
    end
  end
end
