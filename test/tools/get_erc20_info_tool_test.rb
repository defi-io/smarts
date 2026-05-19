require "test_helper"

class GetErc20InfoToolTest < ActiveSupport::TestCase
  setup do
    @tool = GetErc20InfoTool
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  def seed_usdc_like_contract
    # ABI is now just the 6 ERC-20 selectors — admin functions moved to
    # AdminRisk::Profiler and are no longer probed here.
    abi = %w[name symbol decimals totalSupply balanceOf(address) transfer(address,uint256)
             transferFrom(address,address,uint256) approve(address,uint256) allowance(address,address)].map do |sig|
      name, args = sig.split("(")
      arg_types = args.to_s.chomp(")").split(",").reject(&:empty?)
      output_type = case name
      when "name", "symbol" then "string"
      when "decimals" then "uint8"
      else "uint256"
      end
      { "type" => "function", "name" => name,
        "inputs" => arg_types.map { |t| { "type" => t } },
        "outputs" => [ { "type" => output_type } ],
        "stateMutability" => "view" }
    end
    Contract.create!(chain: chains(:ethereum),
                     address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
                     name: "FiatTokenV2_2",
                     abi: abi)
  end

  def stub_multicall_for_erc20
    ->(chain:, calls:) do
      [
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USD Coin" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 10**15 ]) # 1B USDC
      ]
    end
  end

  test "returns token-economics fields for a USDC-like ERC-20 (admin fields no longer included)" do
    seed_usdc_like_contract

    stub_class_method(ChainReader::Multicall3Client, :call, stub_multicall_for_erc20) do
      stub_class_method(DefiLlamaClient, :fetch_prices,
        ->(**_) { { "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" => { "price" => 1.0 } } }) do
        result = @tool.payload(chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")

        assert_equal "USDC", result[:symbol]
        assert_equal "USD Coin", result[:name]
        assert_equal 6, result[:decimals]
        assert_equal 10**15, result[:total_supply][:raw]
        assert_match(/1,000,000,000 USDC/, result[:total_supply][:formatted])
        assert_equal 1.0, result[:price_usd]
        assert_kind_of Numeric, result[:market_cap_usd]
        assert_equal "Circle", result[:issuer][:name]
        # Admin / role fields deliberately removed from this tool — Admin & Risk
        # lives on the contract page and (TODO) a future get_admin_risk MCP tool.
        refute result.key?(:admin_status)
        refute result.key?(:admin_roles)
      end
    end
  end

  test "accepts slug instead of chain+address" do
    seed_usdc_like_contract

    stub_class_method(ChainReader::Multicall3Client, :call, stub_multicall_for_erc20) do
      stub_class_method(DefiLlamaClient, :fetch_prices, ->(**_) { {} }) do
        result = @tool.payload(slug: "usdc-eth")
        assert_equal "USDC", result[:symbol]
      end
    end
  end

  test "returns error when contract is not an ERC-20" do
    non_erc20 = Contract.create!(chain: chains(:ethereum),
                                 address: "0x" + "e" * 40,
                                 name: "Random",
                                 abi: [ { "type" => "function", "name" => "foo", "inputs" => [], "outputs" => [], "stateMutability" => "view" } ])
    result = @tool.payload(chain: "eth", address: non_erc20.address)
    assert_match(/not an ERC-20/, result[:error])
  end

  test "returns error when contract is not indexed" do
    result = @tool.payload(chain: "eth", address: "0x" + "9" * 40)
    assert_match(/not indexed/, result[:error])
  end

  test "exposes block_number and ISO-8601 fetched_at to the AI consumer" do
    seed_usdc_like_contract
    typed_batch = ->(chain:, calls:) do
      ChainReader::Multicall3Client::Batch.new(
        block_number: 24_500_000,
        results: stub_multicall_for_erc20.call(chain: chain, calls: calls)
      )
    end

    stub_class_method(ChainReader::Multicall3Client, :call, typed_batch) do
      stub_class_method(DefiLlamaClient, :fetch_prices, ->(**_) { {} }) do
        result = @tool.payload(chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")

        assert_equal 24_500_000, result[:block_number]
        assert_kind_of String, result[:fetched_at]
        assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, result[:fetched_at],
                     "fetched_at must be ISO-8601")
      end
    end
  end

  test "exposes price_observed_at as ISO-8601 when DefiLlama provides timestamp" do
    seed_usdc_like_contract
    price_ts = 1_700_000_000  # 2023-11-14 22:13:20 UTC
    priced = ->(**_) { { "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" => { "price" => 1.0, "timestamp" => price_ts } } }

    stub_class_method(ChainReader::Multicall3Client, :call, stub_multicall_for_erc20) do
      stub_class_method(DefiLlamaClient, :fetch_prices, priced) do
        result = @tool.payload(chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")

        assert_equal Time.at(price_ts).utc.iso8601, result[:price_observed_at],
                     "AI agents need price freshness independent of on-chain block"
      end
    end
  end

  test "price_observed_at key is present (nil) when DefiLlama omitted timestamp" do
    seed_usdc_like_contract
    no_ts = ->(**_) { { "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" => { "price" => 1.0 } } }

    stub_class_method(ChainReader::Multicall3Client, :call, stub_multicall_for_erc20) do
      stub_class_method(DefiLlamaClient, :fetch_prices, no_ts) do
        result = @tool.payload(chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
        assert result.key?(:price_observed_at)
        assert_nil result[:price_observed_at]
      end
    end
  end

  # If the on-chain multicall for metadata fails, panel_data returns
  # {error: "..."}. The tool must surface it rather than return partial data.
  test "surfaces panel_data errors from the adapter" do
    seed_usdc_like_contract
    all_failed = ->(chain:, calls:) do
      Array.new(calls.length) { ChainReader::Multicall3Client::Result.new(success: false, error: "reverted") }
    end

    stub_class_method(ChainReader::Multicall3Client, :call, all_failed) do
      stub_class_method(DefiLlamaClient, :fetch_prices, ->(**_) { {} }) do
        result = @tool.payload(chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
        assert_match(/could not read token metadata/, result[:error])
      end
    end
  end
end
