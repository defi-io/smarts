require "test_helper"

class GetErc20InfoToolTest < ActiveSupport::TestCase
  setup do
    @tool = GetErc20InfoTool.new
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  def seed_usdc_like_contract
    abi = %w[name symbol decimals totalSupply balanceOf(address) transfer(address,uint256)
             transferFrom(address,address,uint256) approve(address,uint256) allowance(address,address)
             paused owner pauser blacklister masterMinter rescuer].map do |sig|
      name, args = sig.split("(")
      arg_types = args.to_s.chomp(")").split(",").reject(&:empty?)
      output_type = case name
      when "name", "symbol" then "string"
      when "decimals" then "uint8"
      when "paused" then "bool"
      when "owner", "pauser", "blacklister", "masterMinter", "rescuer" then "address"
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

  def stub_multicall_for_erc20_with_admin
    ->(chain:, calls:) do
      [
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USD Coin" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ]),
        ChainReader::Multicall3Client::Result.new(success: true, values: [ 10**15 ]), # 1B USDC
        ChainReader::Multicall3Client::Result.new(success: true, values: [ false ]), # paused
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x1111111111111111111111111111111111111111" ]), # owner
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x2222222222222222222222222222222222222222" ]), # masterMinter
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x3333333333333333333333333333333333333333" ]), # pauser
        ChainReader::Multicall3Client::Result.new(success: true, values: [ "0x4444444444444444444444444444444444444444" ]), # blacklister
        ChainReader::Multicall3Client::Result.new(success: true, values: [ ProtocolAdapters::GenericErc20Adapter::ZERO_ADDRESS ]) # rescuer
      ]
    end
  end

  test "returns full panel data for a USDC-like ERC-20" do
    seed_usdc_like_contract

    stub_class_method(ChainReader::Multicall3Client, :call, stub_multicall_for_erc20_with_admin) do
      stub_class_method(DefiLlamaClient, :fetch_prices,
        ->(**_) { { "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" => { "price" => 1.0 } } }) do
        result = @tool.call(chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")

        assert_equal "USDC", result[:symbol]
        assert_equal "USD Coin", result[:name]
        assert_equal 6, result[:decimals]
        assert_equal 10**15, result[:total_supply][:raw]
        assert_match(/1,000,000,000 USDC/, result[:total_supply][:formatted])
        assert_equal 1.0, result[:price_usd]
        assert_kind_of Numeric, result[:market_cap_usd]
        assert_equal "Circle", result[:issuer][:name]
        assert_equal [ "paused" ], result[:admin_status].map { |s| s[:key] }
        assert_equal %w[owner masterMinter pauser blacklister rescuer], result[:admin_roles].map { |r| r[:key] }
      end
    end
  end

  test "accepts slug instead of chain+address" do
    seed_usdc_like_contract

    stub_class_method(ChainReader::Multicall3Client, :call, stub_multicall_for_erc20_with_admin) do
      stub_class_method(DefiLlamaClient, :fetch_prices, ->(**_) { {} }) do
        result = @tool.call(slug: "usdc-eth")
        assert_equal "USDC", result[:symbol]
      end
    end
  end

  test "returns error when contract is not an ERC-20" do
    non_erc20 = Contract.create!(chain: chains(:ethereum),
                                 address: "0x" + "e" * 40,
                                 name: "Random",
                                 abi: [ { "type" => "function", "name" => "foo", "inputs" => [], "outputs" => [], "stateMutability" => "view" } ])
    result = @tool.call(chain: "eth", address: non_erc20.address)
    assert_match(/not an ERC-20/, result[:error])
  end

  test "returns error when contract is not indexed" do
    result = @tool.call(chain: "eth", address: "0x" + "9" * 40)
    assert_match(/not indexed/, result[:error])
  end

  test "exposes block_number and ISO-8601 fetched_at to the AI consumer" do
    seed_usdc_like_contract
    typed_batch = ->(chain:, calls:) do
      ChainReader::Multicall3Client::Batch.new(
        block_number: 24_500_000,
        results: stub_multicall_for_erc20_with_admin.call(chain: chain, calls: calls)
      )
    end

    stub_class_method(ChainReader::Multicall3Client, :call, typed_batch) do
      stub_class_method(DefiLlamaClient, :fetch_prices, ->(**_) { {} }) do
        result = @tool.call(chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")

        assert_equal 24_500_000, result[:block_number]
        assert_kind_of String, result[:fetched_at]
        assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, result[:fetched_at],
                     "fetched_at must be ISO-8601")
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
        result = @tool.call(chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
        assert_match(/could not read token metadata/, result[:error])
      end
    end
  end
end
