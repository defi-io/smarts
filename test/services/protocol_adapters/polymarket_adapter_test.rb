require "test_helper"

class ProtocolAdapters::PolymarketAdapterTest < ActiveSupport::TestCase
  POLYMARKET_CTF = "0x4d97dcd97ec945f40cf65f87097ace5ea0476045"
  POLYMARKET_EXCHANGE = "0xe111180000d2663c0091e4f400237545b87b996b"
  UMA_ADAPTER = "0x2f5e3684cb1f318ec51b00edba38d79ac2c0aa9d"

  setup do
    @polygon = chains(:polygon)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "matches every curated Polymarket address on Polygon" do
    ProtocolAdapters::PolymarketAdapter::ADDRESSES.each do |address|
      contract = Contract.new(chain: @polygon, address: address)
      assert ProtocolAdapters::PolymarketAdapter.matches?(contract), "expected #{address} to match"
    end
  end

  test "does not match the same address on another chain" do
    contract = Contract.new(chain: chains(:ethereum), address: POLYMARKET_CTF)

    refute ProtocolAdapters::PolymarketAdapter.matches?(contract)
  end

  test "is registered before RPC-backed Uniswap detection" do
    assert_operator ProtocolAdapters::Base::ADAPTER_NAMES.index("PolymarketAdapter"),
                    :<,
                    ProtocolAdapters::Base::ADAPTER_NAMES.index("UniswapV3Adapter")
  end

  test "role controls display_name and template partial" do
    ctf = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_CTF))
    exchange = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_EXCHANGE))
    uma = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: UMA_ADAPTER))

    assert_equal :ctf, ctf.role
    assert_equal "Polymarket Conditional Tokens", ctf.display_name
    assert_equal "protocol_adapters/polymarket_ctf", ctf.template_partial
    assert_equal :exchange, exchange.role
    assert_equal "protocol_adapters/polymarket_exchange", exchange.template_partial
    assert_equal :uma_adapter, uma.role
    assert_equal "protocol_adapters/polymarket_uma_adapter", uma.template_partial
  end

  test "panel_data includes top markets and caches client calls" do
    market = PolymarketClient::Market.new(
      condition_id: "0x" + ("12" * 32),
      slug: "sample",
      question: "Sample?",
      outcomes: [ "Yes", "No" ],
      tokens: [
        PolymarketClient::Token.new(outcome: "Yes", token_id: "101", price: BigDecimal("0.6")),
        PolymarketClient::Token.new(outcome: "No", token_id: "202", price: BigDecimal("0.4"))
      ],
      volume_num: BigDecimal("1000")
    )
    calls = 0
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_EXCHANGE))

    stub_class_method(PolymarketClient, :fetch_top_markets, ->(limit:) { calls += 1; [ market ] }) do
      assert_equal [ market ], adapter.panel_data[:top_markets]
      assert_equal [ market ], adapter.panel_data[:top_markets]
      assert_equal 1, calls
    end
  end

  test "panel_data degrades to an error hash when Gamma fails" do
    adapter = ProtocolAdapters::PolymarketAdapter.new(Contract.new(chain: @polygon, address: POLYMARKET_EXCHANGE))

    stub_class_method(PolymarketClient, :fetch_top_markets, ->(**) { raise PolymarketClient::Error, "down" }) do
      assert_equal "down", adapter.panel_data[:error]
      assert_equal "Order matching", adapter.panel_data[:role_label]
    end
  end
end
