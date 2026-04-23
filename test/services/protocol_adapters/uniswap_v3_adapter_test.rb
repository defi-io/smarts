require "test_helper"

class ProtocolAdapters::UniswapV3AdapterTest < ActiveSupport::TestCase
  V3_FACTORY_ETH = "0x1f98431c8ad98523631ae4a59f267346ea31f984"
  V3_FACTORY_BASE = "0x33128a8fc17869897dce68ed026d694621f6fdfd"

  setup do
    @chain = chains(:ethereum)
    @contract = contracts(:uni_token)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  # ---------- matches? ----------

  test "matches? returns true when factory() equals the chain's V3 factory" do
    stub_class_method(ProtocolAdapters::UniswapV3Adapter, :fetch_factory, ->(_c) { V3_FACTORY_ETH }) do
      assert ProtocolAdapters::UniswapV3Adapter.matches?(@contract)
    end
  end

  test "matches? returns false when factory() points to a different address" do
    stub_class_method(ProtocolAdapters::UniswapV3Adapter, :fetch_factory, ->(_c) { "0xdeadbeef00000000000000000000000000000000" }) do
      refute ProtocolAdapters::UniswapV3Adapter.matches?(@contract)
    end
  end

  test "matches? returns false when factory() reverts or errors (not a V3 pool)" do
    stub_class_method(ProtocolAdapters::UniswapV3Adapter, :fetch_factory, ->(_c) { raise ChainReader::Base::RpcError, "revert" }) do
      refute ProtocolAdapters::UniswapV3Adapter.matches?(@contract)
    end
  end

  test "matches? uses per-chain factory address for Base chain" do
    base_contract = Contract.new(chain: chains(:base), address: "0x#{SecureRandom.hex(20)}")

    stub_class_method(ProtocolAdapters::UniswapV3Adapter, :fetch_factory, ->(_c) { V3_FACTORY_BASE }) do
      assert ProtocolAdapters::UniswapV3Adapter.matches?(base_contract)
    end

    stub_class_method(ProtocolAdapters::UniswapV3Adapter, :fetch_factory, ->(_c) { V3_FACTORY_ETH }) do
      refute ProtocolAdapters::UniswapV3Adapter.matches?(base_contract),
             "Eth factory should not match on Base chain"
    end
  end

  # ---------- format_fee ----------

  test "format_fee renders 500 as 0.05%" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    assert_equal "0.05%", adapter.send(:format_fee, 500)
  end

  test "format_fee renders 3000 as 0.3%" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    assert_equal "0.3%", adapter.send(:format_fee, 3000)
  end

  test "format_fee renders 10000 as 1%" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    assert_equal "1%", adapter.send(:format_fee, 10_000)
  end

  # ---------- price_token1_per_token0 ----------

  test "price of 1 when sqrtPriceX96 equals 2**96 and decimals match" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    q96 = 2**96

    price = adapter.send(:price_token1_per_token0, q96, 18, 18)
    assert_in_delta 1.0, price, 1e-9
  end

  test "price reflects sqrtPriceX96 squared (2x sqrt = 4x price)" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    q96 = 2**96

    price = adapter.send(:price_token1_per_token0, q96 * 2, 18, 18)
    assert_in_delta 4.0, price, 1e-9
  end

  test "price adjusts for decimal difference between tokens" do
    # USDC/WETH sqrtPriceX96 ≈ 1.644e33 → price ≈ 4.3e8 raw → 4.3e-4 after 10^(6-18)
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    sqrt_price_x96 = 1_644_253_472_768_517_942_471_065_231_332_056

    price = adapter.send(:price_token1_per_token0, sqrt_price_x96, 6, 18)
    assert_in_delta 4.307e-4, price, 5e-7
  end

  test "price returns nil for zero sqrtPriceX96" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    assert_nil adapter.send(:price_token1_per_token0, 0, 18, 18)
  end

  # ---------- compute_tvl ----------

  test "compute_tvl sums reserve × price / 10^decimals for both tokens" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    t0 = { reserve: 10_000_000_000, decimals: 6 }           # 10,000 USDC
    t1 = { reserve: (5.0 * 10**18).to_i, decimals: 18 }     # 5 WETH
    prices = {
      "0xaaaa" => { "price" => 1.0 },
      "0xbbbb" => { "price" => 2000.0 }
    }

    tvl = adapter.send(:compute_tvl, t0, t1, prices, "0xAAAA", "0xBBBB")
    assert_equal 20_000.0, tvl  # 10000 + 5×2000
  end

  test "compute_tvl returns nil when a reserve is missing" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    t0 = { reserve: nil, decimals: 6 }
    t1 = { reserve: 10**18, decimals: 18 }
    prices = { "0xa" => { "price" => 1.0 }, "0xb" => { "price" => 2000.0 } }

    assert_nil adapter.send(:compute_tvl, t0, t1, prices, "0xa", "0xb")
  end

  test "compute_tvl returns nil when a USD price is missing" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    t0 = { reserve: 10_000, decimals: 6 }
    t1 = { reserve: 10**18, decimals: 18 }
    prices = { "0xa" => { "price" => 1.0 } }  # 0xb missing

    assert_nil adapter.send(:compute_tvl, t0, t1, prices, "0xa", "0xb")
  end

  # ---------- degradation paths ----------

  test "panel_data returns {error: ...} when pool state multicall has any failure" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)

    # Return 5 results but one is failed — read_pool_state returns nil, which
    # surfaces as error in panel_data.
    one_failed = lambda do |chain:, calls:|
      [
        ChainReader::Multicall3Client::Result.new(success: true,  values: [ "0xtoken0" ]),
        ChainReader::Multicall3Client::Result.new(success: true,  values: [ "0xtoken1" ]),
        ChainReader::Multicall3Client::Result.new(success: true,  values: [ 500 ]),
        ChainReader::Multicall3Client::Result.new(success: false, error: "execution reverted"),
        ChainReader::Multicall3Client::Result.new(success: true,  values: [ [ 1, 2, 0, 0, 0, 0, false ] ])
      ]
    end

    stub_class_method(ChainReader::Multicall3Client, :call, one_failed) do
      data = adapter.panel_data
      assert_equal "pool state unreadable", data[:error]
    end
  end

  test "panel_data omits tvl_usd when DefiLlama price fetch raises" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)

    multicall_stub = lambda do |chain:, calls:|
      if calls.first.function["name"] == "token0"
        [
          ChainReader::Multicall3Client::Result.new(success: true, values: [ "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ 500 ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ 1_000 ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ [ 2**96, 0, 0, 0, 0, 0, false ] ])
        ]
      else
        [
          ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ 1_000_000 ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ "WETH" ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ 18 ]),
          ChainReader::Multicall3Client::Result.new(success: true, values: [ 10**18 ])
        ]
      end
    end

    down = ->(**_) { raise DefiLlamaClient::Error, "DefiLlama is down" }

    stub_class_method(ChainReader::Multicall3Client, :call, multicall_stub) do
      stub_class_method(DefiLlamaClient, :fetch_prices, down) do
        data = adapter.panel_data
        assert_nil data[:tvl_usd], "TVL should be nil when price fetch fails"
        assert_equal "USDC", data[:token0][:symbol], "pool info should still render"
        assert_equal "WETH", data[:token1][:symbol]
        assert_equal "0.05%", data[:fee_pct]
      end
    end
  end

  # ---------- display_name ----------

  test "display_name composes pair and fee from panel_data" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    adapter.define_singleton_method(:panel_data) do
      { token0: { symbol: "USDC" }, token1: { symbol: "WETH" }, fee_pct: "0.05%" }
    end
    assert_equal "USDC/WETH 0.05%", adapter.display_name
  end

  test "display_name returns nil when panel_data is an error result" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)
    adapter.define_singleton_method(:panel_data) do
      { error: "pool state unreadable" }
    end
    assert_nil adapter.display_name
  end

  test "display_name returns nil when either token symbol is missing / unknown" do
    adapter = ProtocolAdapters::UniswapV3Adapter.new(@contract)

    # The adapter's token-read code returns "?" as a sentinel when a symbol
    # call reverts. display_name must treat it as a data gap, not render
    # "?/WETH 0.05%".
    [
      { token0: { symbol: "?"    }, token1: { symbol: "WETH" }, fee_pct: "0.05%" },
      { token0: { symbol: "USDC" }, token1: { symbol: "?"    }, fee_pct: "0.05%" },
      { token0: { symbol: nil    }, token1: { symbol: "WETH" }, fee_pct: "0.05%" },
      { token0: { symbol: "USDC" }, token1: { symbol: "WETH" }, fee_pct: nil    }
    ].each_with_index do |stub, i|
      adapter.define_singleton_method(:panel_data) { stub }
      assert_nil adapter.display_name, "case #{i}: expected nil for #{stub.inspect}"
    end
  end
end
