require "test_helper"

# get_stablecoin_supply / get_protocol_tvl / get_yield_pools read the slimmed
# datasets from DefiLlamaDatasets; stub those directly.
class DefillamaDatasetToolsTest < ActiveSupport::TestCase
  STABLES = [
    { name: "USD Coin", symbol: "USDC", peg_type: "peggedUSD", peg_mechanism: "fiat-backed", price: 0.9997,
      circulating: 70_000.0, circulating_prev_day: 70_175.0, circulating_prev_week: 71_000.0,
      chains: [ [ "eth", 42_000.0 ], [ "Solana", 7_000.0 ], [ "base", 4_200.0 ] ] },
    { name: "Bridged USDC (fake)", symbol: "USDC", peg_type: "peggedUSD", peg_mechanism: "crypto-backed", price: 1.0,
      circulating: 10.0, circulating_prev_day: 10.0, circulating_prev_week: 10.0, chains: [] }
  ].freeze

  PROTOCOLS = [
    { name: "Aave V3", slug: "aave-v3", category: "Lending", tvl_usd: 15_000.0, borrowed_usd: 11_000.0, change_1d: -1.27179, change_7d: -0.91168,
      url: "https://aave.com", chains: [ [ "eth", 12_000.0 ], [ "base", 500.0 ] ] },
    { name: "Morpho Blue", slug: "morpho-blue", category: "Lending", tvl_usd: 10_000.0, chains: [] },
    { name: "Morpho Midnight", slug: "morpho-midnight", category: "Lending", tvl_usd: 160.0, chains: [] }
  ].freeze

  POOLS = [
    { pool: "a", project: "aave-v3",       chain: "arbitrum", symbol: "USDC",      tvl_usd: 200_000_000, apy: 4.6, stablecoin: true },
    { pool: "b", project: "fluid-lending", chain: "arbitrum", symbol: "USDC",      tvl_usd: 54_000_000,  apy: 4.9, stablecoin: true },
    { pool: "c", project: "gmx-evm",       chain: "arbitrum", symbol: "ETH-USDC",  tvl_usd: 45_000_000,  apy: 3.3, stablecoin: false },
    { pool: "d", project: "aave-v3",       chain: "base",     symbol: "USDC",      tvl_usd: 300_000_000, apy: 4.7, stablecoin: true },
    { pool: "e", project: "tiny",          chain: "arbitrum", symbol: "USDC",      tvl_usd: 50_000,      apy: 90.0, stablecoin: true }
  ].freeze

  FETCHED_AT = Time.utc(2026, 11, 10, 2, 50, 0)

  def with_datasets(stables: STABLES, protocols: PROTOCOLS, pools: POOLS, &block)
    stub_class_method(DefiLlamaDatasets, :fetched_at, ->(_name) { FETCHED_AT }) do
      with_dataset_rows(stables, protocols, pools, &block)
    end
  end

  def with_dataset_rows(stables, protocols, pools, &block)
    stub_class_method(DefiLlamaDatasets, :stablecoins, -> { stables }) do
      stub_class_method(DefiLlamaDatasets, :protocols, -> { protocols }) do
        stub_class_method(DefiLlamaDatasets, :yield_pools, -> { pools }, &block)
      end
    end
  end

  # ---------- get_stablecoin_supply ----------

  test "stablecoin supply picks the largest match and reports changes and one chain" do
    with_datasets do
      r = GetStablecoinSupplyTool.payload(symbol: "usdc", chain: "base")

      assert_equal "USD Coin", r[:name]
      assert_equal 70_000.0, r[:circulating]
      assert_equal(-0.249, r[:change_1d_pct])
      assert_equal(-1.408, r[:change_7d_pct])
      assert_equal 3, r[:chain_count]
      assert_equal({ chain: "eth", circulating: 42_000.0 }, r[:top_chains].first)
      assert_equal({ chain: "base", circulating: 4_200.0, share_pct: 6.0 }, r[:chain])
      assert_equal [ "Bridged USDC (fake)" ], r[:other_matches].map { |m| m[:name] }
      assert_equal "2026-11-10T02:50:00Z", r[:fetched_at], "datasets can be up to 10 min old"
    end
  end

  test "stablecoin supply errors for unknown symbols, unsupported chains and DefiLlama failures" do
    with_datasets do
      assert_equal "no stablecoin with symbol 'NOPE' on DefiLlama", GetStablecoinSupplyTool.payload(symbol: "NOPE")[:error]
      assert_match(/unsupported chain: solana/, GetStablecoinSupplyTool.payload(symbol: "USDC", chain: "solana")[:error])
    end

    stub_class_method(DefiLlamaDatasets, :stablecoins, -> { raise DefiLlamaDatasets::Error, "DefiLlama returned 502" }) do
      assert_equal "DefiLlama returned 502", GetStablecoinSupplyTool.payload(symbol: "USDC")[:error]
    end
  end

  # ---------- get_protocol_tvl ----------

  test "protocol TVL matches by slug or name" do
    with_datasets do
      by_slug = GetProtocolTvlTool.payload(protocol: "aave-v3")
      assert_equal "Aave V3", by_slug[:name]
      assert_equal 15_000.0, by_slug[:tvl_usd]
      assert_equal 11_000.0, by_slug[:borrowed_usd]
      assert_equal(-1.272, by_slug[:change_1d_pct])
      assert_equal [ { chain: "eth", tvl_usd: 12_000.0 }, { chain: "base", tvl_usd: 500.0 } ], by_slug[:top_chains]
      assert_equal "2026-11-10T02:50:00Z", by_slug[:fetched_at]

      assert_equal "aave-v3", GetProtocolTvlTool.payload(protocol: "Aave V3")[:slug]
    end
  end

  test "protocol TVL suggests close names, largest first, when nothing matches" do
    with_datasets do
      r = GetProtocolTvlTool.payload(protocol: "morpho")
      assert_equal "no DefiLlama protocol 'morpho'", r[:error]
      assert_equal %w[morpho-blue morpho-midnight], r[:suggestions].map { |s| s[:slug] }
    end
  end

  # ---------- get_yield_pools ----------

  test "yield pools filter by chain, symbol substring and the default 1M TVL floor" do
    with_datasets do
      r = GetYieldPoolsTool.payload(chain: "arbitrum", symbol: "usdc")
      assert_equal %w[a b c], r[:pools].map { |p| p[:pool] }, "sorted by TVL; the $50k pool is below the floor"
      assert_equal 3, r[:match_count]
      assert_equal "tvl", r[:filters][:sort]
      assert_equal "2026-11-10T02:50:00Z", r[:fetched_at]
    end
  end

  test "yield pools filter by project and stablecoin flag, sort by APY and cap the limit" do
    with_datasets do
      assert_equal %w[d a], GetYieldPoolsTool.payload(project: "aave-v3")[:pools].map { |p| p[:pool] }
      assert_equal %w[b a], GetYieldPoolsTool.payload(chain: "arbitrum", stablecoin_only: true, sort: "apy")[:pools].map { |p| p[:pool] }
      assert_equal %w[d], GetYieldPoolsTool.payload(limit: 1)[:pools].map { |p| p[:pool] }
      assert_equal 5, GetYieldPoolsTool.payload(min_tvl_usd: 0, limit: 999)[:pools].size
    end
  end

  test "yield pools reject unsupported chains" do
    with_datasets do
      assert_match(/unsupported chain: solana/, GetYieldPoolsTool.payload(chain: "solana")[:error])
    end
  end
end
