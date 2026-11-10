require "test_helper"

class ProtocolAdapters::AaveV3PoolAdapterTest < ActiveSupport::TestCase
  Adapter = ProtocolAdapters::AaveV3PoolAdapter
  Result = ChainReader::Multicall3Client::Result

  BASE_POOL = "0xa238dd80c259a72e81d7e4664a9801593f98d1c5"
  USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  WETH = "0x4200000000000000000000000000000000000006"

  # Packs a ReserveConfigurationMap the way ReserveConfiguration.sol does.
  def self.config(ltv:, threshold:, bonus:, decimals:, reserve_factor:, borrow_cap: 0, supply_cap: 0,
                  active: true, frozen: false, borrowing: true, paused: false)
    ltv | (threshold << 16) | (bonus << 32) | (decimals << 48) |
      ((active ? 1 : 0) << 56) | ((frozen ? 1 : 0) << 57) | ((borrowing ? 1 : 0) << 58) | ((paused ? 1 : 0) << 60) |
      (reserve_factor << 64) | (borrow_cap << 80) | (supply_cap << 116)
  end

  # 5% APR in ray
  FIVE_PCT_RAY = 5 * 10**25

  RESERVES = {
    USDC => { symbol: "USDC", a_token: "0xa000000000000000000000000000000000000001", debt: "0xd000000000000000000000000000000000000001",
              config: config(ltv: 0, threshold: 7800, bonus: 10_450, decimals: 6, reserve_factor: 1000, borrow_cap: 2_750_000_000, supply_cap: 3_500_000_000),
              supply_rate: FIVE_PCT_RAY, borrow_rate: 2 * FIVE_PCT_RAY,
              a_supply: 1_000_000 * 10**6, debt_supply: 900_000 * 10**6 },
    WETH => { symbol: "WETH", a_token: "0xa000000000000000000000000000000000000002", debt: "0xd000000000000000000000000000000000000002",
              config: config(ltv: 8100, threshold: 8400, bonus: 10_500, decimals: 18, reserve_factor: 1500, frozen: true),
              supply_rate: 0, borrow_rate: FIVE_PCT_RAY,
              a_supply: 1_000 * 10**18, debt_supply: 500 * 10**18 }
  }.freeze

  setup do
    @chain = chains(:base)
    @contract = Contract.new(chain: @chain, address: BASE_POOL)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  def fake_multicall(list_success: true)
    by_token = RESERVES.flat_map { |asset, r| [ [ r[:a_token], r[:a_supply] ], [ r[:debt], r[:debt_supply] ] ] }.to_h

    lambda do |chain:, calls:|
      results = calls.map do |c|
        case c.function["name"]
        when "getReservesList"
          list_success ? Result.new(success: true, values: [ RESERVES.keys ]) : Result.new(success: false, error: "execution reverted")
        when "getReserveData"
          r = RESERVES.fetch(c.args.first)
          Result.new(success: true, values: [ [ r[:config], 10**27, r[:supply_rate], 10**27, r[:borrow_rate], 0, 0, 0,
                                                r[:a_token], "0x" + "0" * 40, r[:debt], "0x" + "0" * 40, 0, 0, 0 ] ])
        when "symbol"
          Result.new(success: true, values: [ RESERVES.fetch(c.target)[:symbol] ])
        when "totalSupply"
          Result.new(success: true, values: [ by_token.fetch(c.target) ])
        end
      end
      ChainReader::Multicall3Client::Batch.new(block_number: 30_000_000, results: results)
    end
  end

  def with_market(prices: { USDC => { "price" => 1.0, "timestamp" => 1_700_000_000 }, WETH => { "price" => 3000.0, "timestamp" => 1_700_000_100 } }, **opts, &block)
    stub_class_method(ChainReader::Multicall3Client, :call, fake_multicall(**opts)) do
      stub_class_method(DefiLlamaClient, :fetch_prices, ->(**_) { prices }, &block)
    end
  end

  test "matches? only the canonical Pool proxy on that chain" do
    assert Adapter.matches?(@contract)
    refute Adapter.matches?(Contract.new(chain: @chain, address: "0x794a61358d6845594f94dc1db02a252b5b4814ad")),
           "Arbitrum/Optimism Pool address must not match on Base"
    refute Adapter.matches?(Contract.new(chain: chains(:robinhood), address: BASE_POOL))
  end

  test "is registered ahead of the generic ERC-20 fallback" do
    names = ProtocolAdapters::Base::ADAPTER_NAMES
    assert_includes names, "AaveV3PoolAdapter"
    assert_operator names.index("AaveV3PoolAdapter"), :<, names.index("GenericErc20Adapter")
  end

  test "decode_configuration unpacks the reserve bitmap" do
    cfg = Adapter.decode_configuration(RESERVES[USDC][:config])
    assert_equal 0, cfg[:ltv_bps]
    assert_equal 7800, cfg[:liquidation_threshold_bps]
    assert_equal 10_450, cfg[:liquidation_bonus_bps]
    assert_equal 6, cfg[:decimals]
    assert cfg[:active]
    refute cfg[:frozen]
    assert cfg[:borrowing_enabled]
    refute cfg[:paused]
    assert_equal 1000, cfg[:reserve_factor_bps]
    assert_equal 2_750_000_000, cfg[:borrow_cap]
    assert_equal 3_500_000_000, cfg[:supply_cap]
  end

  test "ray_rate_to_apy compounds per second" do
    assert_in_delta 0.05127, Adapter.ray_rate_to_apy(FIVE_PCT_RAY), 1e-4
    assert_equal 0.0, Adapter.ray_rate_to_apy(0)
  end

  test "panel_data builds reserves with USD totals, sorted by supplied USD" do
    data = with_market { Adapter.new(@contract).panel_data }

    assert_equal 2, data[:reserve_count]
    assert_equal %w[WETH USDC], data[:reserves].map { |r| r[:symbol] }, "WETH ($3M) sorts above USDC ($1M)"
    assert_equal 4_000_000.0, data[:total_supplied_usd]
    assert_equal 2_400_000.0, data[:total_borrowed_usd]
    assert_equal 30_000_000, data[:block_number]
    assert_equal Time.at(1_700_000_000), data[:price_observed_at], "oldest price timestamp wins"

    usdc = data[:reserves].find { |r| r[:symbol] == "USDC" }
    assert_equal USDC, usdc[:address]
    assert_equal 1_000_000.0, usdc[:total_supplied]
    assert_equal 900_000.0, usdc[:total_borrowed]
    assert_in_delta 0.9, usdc[:utilization], 1e-9
    assert_in_delta 0.05127, usdc[:supply_apy], 1e-4
    assert_equal 0.0, usdc[:ltv]
    assert_in_delta 0.78, usdc[:liquidation_threshold], 1e-9
    assert_in_delta 0.045, usdc[:liquidation_bonus], 1e-9
    assert_in_delta 0.10, usdc[:reserve_factor], 1e-9
    assert_equal 3_500_000_000, usdc[:supply_cap]

    weth = data[:reserves].find { |r| r[:symbol] == "WETH" }
    assert weth[:frozen]
    assert_nil weth[:supply_cap], "zero cap means uncapped"
    assert_equal 3_000_000.0, weth[:supplied_usd]
  end

  test "panel_data leaves USD nil when DefiLlama has no price" do
    data = with_market(prices: {}) { Adapter.new(@contract).panel_data }

    assert_nil data[:total_supplied_usd]
    assert(data[:reserves].all? { |r| r[:supplied_usd].nil? })
    assert_equal 1_000_000.0, data[:reserves].find { |r| r[:symbol] == "USDC" }[:total_supplied]
  end

  test "panel_data reports an error when the reserve list is unreadable" do
    data = with_market(list_success: false) { Adapter.new(@contract).panel_data }
    assert_equal "reserve list unreadable", data[:error]
  end

  test "display_name is the brand name" do
    assert_equal "Aave V3 Pool", Adapter.new(@contract).display_name
  end
end
