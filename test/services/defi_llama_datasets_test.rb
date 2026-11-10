require "test_helper"

class DefiLlamaDatasetsTest < ActiveSupport::TestCase
  STABLECOINS = {
    "peggedAssets" => [
      { "name" => "USD Coin", "symbol" => "USDC", "pegType" => "peggedUSD", "pegMechanism" => "fiat-backed", "price" => 0.9998,
        "circulating" => { "peggedUSD" => 70_000.0 }, "circulatingPrevDay" => { "peggedUSD" => 69_000.0 }, "circulatingPrevWeek" => { "peggedUSD" => 71_000.0 },
        "chainCirculating" => {
          "Base"       => { "current" => { "peggedUSD" => 4_000.0 } },
          "Ethereum"   => { "current" => { "peggedUSD" => 42_000.0 } },
          "Solana"     => { "current" => { "peggedUSD" => 7_000.0 } },
          "OP Mainnet" => { "current" => {} }
        } }
    ]
  }.freeze

  PROTOCOLS = [
    { "name" => "Aave V3", "slug" => "aave-v3", "category" => "Lending", "tvl" => 15_000.0, "change_1d" => -1.27, "change_7d" => -0.91, "url" => "https://aave.com",
      "chainTvls" => { "Ethereum" => 12_000.0, "Ethereum-borrowed" => 9_000.0, "Base" => 500.0, "Base-borrowed" => 300.0,
                       "Optimism" => 70.0, "Binance" => 260.0, "Plasma" => 2_170.0, "borrowed" => 9_300.0, "staking" => 5.0 } }
  ].freeze

  POOLS = {
    "data" => [
      { "pool" => "p1", "project" => "aave-v3", "chain" => "Arbitrum", "symbol" => "USDC", "tvlUsd" => 200_000_000, "apy" => 4.6, "apyBase" => 4.6,
        "apyReward" => nil, "apyMean30d" => 4.1, "apyPct7D" => 0.2, "stablecoin" => true, "ilRisk" => "no", "exposure" => "single", "underlyingTokens" => [ "0xaf88" ] },
      { "pool" => "p2", "project" => "aave-v3", "chain" => "OP Mainnet", "symbol" => "WETH", "tvlUsd" => 5_000_000, "apy" => 1.4, "stablecoin" => false },
      { "pool" => "p3", "project" => "jito", "chain" => "Solana", "symbol" => "JITOSOL", "tvlUsd" => 900_000_000, "apy" => 7.0 }
    ]
  }.freeze

  setup do
    @original_store = DefiLlamaDatasets.store
    DefiLlamaDatasets.store = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    DefiLlamaDatasets.store = @original_store
  end

  def stub_json(url, body)
    stub_request(:get, url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  test "stablecoins are slimmed, mapped to our chain slugs and sorted per chain" do
    stub_json(DefiLlamaDatasets::STABLECOINS_URL, STABLECOINS)
    usdc = DefiLlamaDatasets.stablecoins.first

    assert_equal "USDC", usdc[:symbol]
    assert_equal 70_000.0, usdc[:circulating]
    assert_equal 69_000.0, usdc[:circulating_prev_day]
    assert_equal [ [ "eth", 42_000.0 ], [ "Solana", 7_000.0 ], [ "base", 4_000.0 ] ], usdc[:chains],
                 "our chains use our slugs, others keep DefiLlama's name; chains with no current figure are dropped"
  end

  test "protocol chain TVLs drop borrowed/staking breakdowns and use the protocols-API chain names" do
    stub_json(DefiLlamaDatasets::PROTOCOLS_URL, PROTOCOLS)
    aave = DefiLlamaDatasets.protocols.first

    assert_equal %w[eth Plasma base bnb optimism], aave[:chains].map(&:first)
    assert_equal 9_300.0, aave[:borrowed_usd], "sum of <chain>-borrowed"
    assert_equal 15_000.0, aave[:tvl_usd]
  end

  test "yield pools keep only supported chains" do
    stub_json(DefiLlamaDatasets::POOLS_URL, POOLS)
    pools = DefiLlamaDatasets.yield_pools

    assert_equal %w[p1 p2], pools.map { |p| p[:pool] }
    assert_equal %w[arbitrum optimism], pools.map { |p| p[:chain] }
    assert_equal 4.1, pools.first[:apy_mean_30d]
    assert_equal 0.2, pools.first[:apy_change_7d]
  end

  test "each dataset is downloaded once per TTL" do
    request = stub_json(DefiLlamaDatasets::POOLS_URL, POOLS)
    3.times { DefiLlamaDatasets.yield_pools }
    assert_requested request, times: 1
  end

  test "HTTP failures and malformed bodies raise DefiLlamaDatasets::Error" do
    stub_request(:get, DefiLlamaDatasets::POOLS_URL).to_return(status: 502, body: "bad gateway")
    assert_raises(DefiLlamaDatasets::Error) { DefiLlamaDatasets.yield_pools }

    stub_json(DefiLlamaDatasets::STABLECOINS_URL, { "unexpected" => [] })
    assert_raises(DefiLlamaDatasets::Error) { DefiLlamaDatasets.stablecoins }
  end
end
