require "test_helper"

class GetAaveV3MarketToolTest < ActiveSupport::TestCase
  BASE_POOL = "0xa238dd80c259a72e81d7e4664a9801593f98d1c5"

  RESERVES = [
    { symbol: "WETH", address: "0x4200000000000000000000000000000000000006", supply_apy: 0.0136, supplied_usd: 3_000_000.0 },
    { symbol: "USDC", address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", supply_apy: 0.0473, supplied_usd: 1_000_000.0 }
  ].freeze

  PANEL = {
    reserves: RESERVES, reserve_count: 2,
    total_supplied_usd: 4_000_000.0, total_borrowed_usd: 2_400_000.0,
    block_number: 30_000_000, fetched_at: Time.utc(2026, 11, 9, 12, 0, 0), price_observed_at: Time.utc(2026, 11, 9, 11, 59, 0)
  }.freeze

  def with_panel(panel = PANEL, &block)
    captured = []
    ProtocolAdapters::AaveV3PoolAdapter.class_eval do
      alias_method :__orig_panel_data, :panel_data
      define_method(:panel_data) do
        captured << contract.address
        panel
      end
    end
    block.call(captured)
  ensure
    ProtocolAdapters::AaveV3PoolAdapter.class_eval do
      alias_method :panel_data, :__orig_panel_data
      remove_method :__orig_panel_data
    end
  end

  test "returns the whole market for a chain" do
    with_panel do |pools|
      result = GetAaveV3MarketTool.payload(chain: "base")

      assert_equal [ BASE_POOL ], pools, "reads the canonical Base Pool"
      assert_equal "Aave V3", result[:protocol]
      assert_equal "base", result[:chain]
      assert_equal BASE_POOL, result[:pool]
      assert_equal 4_000_000.0, result[:total_supplied_usd]
      assert_equal 2, result[:reserves].size
      assert_equal 30_000_000, result[:block_number]
      assert_equal "2026-11-09T12:00:00Z", result[:fetched_at]
      assert_equal "2026-11-09T11:59:00Z", result[:price_observed_at]
      assert_match "LTV 0", result[:rates_note]
    end
  end

  test "filters to one reserve by symbol (case-insensitive) or address" do
    with_panel do
      by_symbol = GetAaveV3MarketTool.payload(chain: "base", asset: "usdc")
      assert_equal [ "USDC" ], by_symbol[:reserves].map { |r| r[:symbol] }

      by_address = GetAaveV3MarketTool.payload(chain: "base", asset: "0x4200000000000000000000000000000000000006")
      assert_equal [ "WETH" ], by_address[:reserves].map { |r| r[:symbol] }

      missing = GetAaveV3MarketTool.payload(chain: "base", asset: "DOGE")
      assert_equal "no reserve matching 'DOGE' in Aave V3 on base", missing[:error]
    end
  end

  test "accepts the curated Aave pool slug" do
    with_panel do
      result = GetAaveV3MarketTool.payload(slug: "aavev3-pool-base")
      assert_equal "base", result[:chain]
    end
  end

  test "rejects slugs that are not an Aave V3 Pool" do
    assert_equal "usdc-eth is not an Aave V3 Pool", GetAaveV3MarketTool.payload(slug: "usdc-eth")[:error]
    assert_equal "unknown slug: nope-eth", GetAaveV3MarketTool.payload(slug: "nope-eth")[:error]
  end

  test "errors for chains without an Aave V3 market, unknown chains and missing input" do
    assert_match(/no Aave V3 market on robinhood/, GetAaveV3MarketTool.payload(chain: "robinhood")[:error])
    assert_equal "unknown chain: solana", GetAaveV3MarketTool.payload(chain: "solana")[:error]
    assert_equal "either `chain` or `slug` required", GetAaveV3MarketTool.payload[:error]
  end

  test "passes adapter read errors through" do
    with_panel({ error: "reserve list unreadable" }) do
      assert_equal "reserve list unreadable", GetAaveV3MarketTool.payload(chain: "base")[:error]
    end
  end
end
