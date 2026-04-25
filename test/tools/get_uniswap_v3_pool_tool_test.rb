require "test_helper"

class GetUniswapV3PoolToolTest < ActiveSupport::TestCase
  setup do
    @tool = GetUniswapV3PoolTool.new
    @contract = contracts(:uni_token)  # not a V3 pool; re-use as non-matching case
  end

  test "returns error for unknown chain" do
    result = @tool.call(chain: "solana", address: "0x0")
    assert_equal "unknown chain: solana", result[:error]
  end

  test "returns error when contract not indexed" do
    result = @tool.call(chain: "eth", address: "0x" + "a" * 40)
    assert_match(/not indexed/, result[:error])
  end

  test "returns error when the contract isn't a V3 pool" do
    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_c) { nil }) do
      result = @tool.call(chain: "eth", address: @contract.address)
      assert_equal "not a Uniswap V3 pool", result[:error]
    end
  end

  test "returns structured panel data for a V3 pool" do
    fake_adapter = FakeV3Adapter.new(canned_panel_data)

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_c) { fake_adapter }) do
      result = @tool.call(chain: "eth", address: @contract.address)

      assert_equal "Uniswap V3",    result[:protocol]
      assert_equal "USDC/WETH",     result[:pair]
      assert_equal "0.05%",         result[:fee]
      assert_equal 198_819,         result[:tick]
      assert_equal 100_000_000.0,   result[:tvl_usd]
      assert_equal "USDC",          result[:tokens][:token0][:symbol]
      assert_equal "WETH",          result[:tokens][:token1][:symbol]
      assert_includes result[:price].keys, "1 WETH in USDC"
      assert_includes result[:price].keys, "1 USDC in WETH"
    end
  end

  test "exposes block_number and ISO-8601 fetched_at to the AI consumer" do
    panel = canned_panel_data.merge(block_number: 24_500_000, fetched_at: Time.utc(2026, 4, 25, 14, 30, 0))
    fake_adapter = FakeV3Adapter.new(panel)

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_c) { fake_adapter }) do
      result = @tool.call(chain: "eth", address: @contract.address)
      assert_equal 24_500_000, result[:block_number],
                   "AI agents need the block anchor to verify state on-chain"
      assert_equal "2026-04-25T14:30:00Z", result[:fetched_at],
                   "fetched_at must be ISO-8601 so cross-tool correlation works"
    end
  end

  test "surfaces panel errors from the adapter" do
    fake_adapter = FakeV3Adapter.new({ error: "pool state unreadable" })

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_c) { fake_adapter }) do
      result = @tool.call(chain: "eth", address: @contract.address)
      assert_equal "pool state unreadable", result[:error]
    end
  end

  test "accepts a slug instead of chain+address" do
    # Seed a V3 pool contract at the canonical univ3-usdc-weth-eth slug address
    pool = Contract.create!(chain: chains(:ethereum),
                            address: "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640",
                            name: "V3 Pool", abi: [])
    fake_adapter = FakeV3Adapter.new(canned_panel_data)

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_c) { fake_adapter }) do
      result = @tool.call(slug: "univ3-usdc-weth-eth")
      assert_equal "Uniswap V3", result[:protocol]
      assert_equal "USDC/WETH", result[:pair]
    end
  end

  test "returns error for unknown slug" do
    result = @tool.call(slug: "nonexistent-eth")
    assert_match(/unknown slug/, result[:error])
  end

  private

  def canned_panel_data
    {
      token0: { symbol: "USDC", decimals: 6, address: "0xa0b8..." },
      token1: { symbol: "WETH", decimals: 18, address: "0xc02a..." },
      fee_pct: "0.05%",
      tick: 198_819,
      liquidity: 3_100_000_000_000_000_000,
      sqrt_price_x96: 1_644_253_472_768_517_942_471_065_231_332_056,
      price_0_per_1: 2_322.29,
      price_1_per_0: 0.00043,
      tvl_usd: 100_000_000.0,
      usd_prices: {}
    }
  end

  class FakeV3Adapter < ProtocolAdapters::UniswapV3Adapter
    def initialize(canned_data)
      @canned_data = canned_data
      # Skip parent initialize — we don't need a real contract
    end

    def panel_data
      @canned_data
    end
  end
end
