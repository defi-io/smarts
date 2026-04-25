require "test_helper"

class ChainReader::ViewCallerTest < ActiveSupport::TestCase
  setup do
    @chain = chains(:ethereum)
    @contract = build_contract_with_abi(mixed_abi)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "only passes zero-arg view/pure functions to Multicall3Client" do
    captured_calls = []
    spy = lambda do |chain:, calls:|
      captured_calls = calls
      calls.map { ChainReader::Multicall3Client::Result.new(success: true, values: [ 0 ]) }
    end

    stub_class_method(ChainReader::Multicall3Client, :call, spy) do
      ChainReader::ViewCaller.call(@contract)
    end

    names = captured_calls.map { |c| c.function["name"] }.sort
    assert_equal [ "name", "totalSupply" ], names
  end

  test "caches results for 60s; second call does not hit Multicall3Client" do
    invocation_count = 0
    spy = lambda do |chain:, calls:|
      invocation_count += 1
      calls.map { ChainReader::Multicall3Client::Result.new(success: true, values: [ 1 ]) }
    end

    stub_class_method(ChainReader::Multicall3Client, :call, spy) do
      ChainReader::ViewCaller.call(@contract)
      ChainReader::ViewCaller.call(@contract)
      ChainReader::ViewCaller.call(@contract)
    end

    assert_equal 1, invocation_count
  end

  test "falls back to individual eth_call on multicall RpcError" do
    raising = ->(chain:, calls:) { raise ChainReader::Base::RpcError, "multicall failed" }

    name_hex = "0x" + Eth::Abi.encode([ "string" ], [ "Uniswap" ]).unpack1("H*")
    supply_hex = "0x" + Eth::Abi.encode([ "uint256" ], [ 42 ]).unpack1("H*")

    single_call_count = 0
    single_stub = lambda do |_chain, to:, data:|
      single_call_count += 1
      selector = data[0, 10]
      case selector
      when ChainReader::Base.selector("name()") then name_hex
      when ChainReader::Base.selector("totalSupply()") then supply_hex
      else raise "unexpected selector: #{selector}"
      end
    end

    stub_class_method(ChainReader::Multicall3Client, :call, raising) do
      stub_class_method(ChainReader::Base, :eth_call_hex, single_stub) do
        results = ChainReader::ViewCaller.call(@contract)

        assert_equal 2, single_call_count, "should fall back to one eth_call per zero-arg function"
        assert(results.values.all?(&:success))
        assert_equal [ "Uniswap" ], results["name()"].values
        assert_equal [ 42 ], results["totalSupply()"].values
      end
    end
  end

  test "keys result hash by full function signature" do
    stub_multicall_success_returning(1) do
      results = ChainReader::ViewCaller.call(@contract)
      assert_includes results.keys, "name()"
      assert_includes results.keys, "totalSupply()"
      refute_includes results.keys, "balanceOf(address)"
    end
  end

  test "cache key isolates same address on different chains" do
    base_chain = chains(:base)
    eth_contract = @contract
    base_contract = Contract.create!(
      chain: base_chain,
      address: @contract.address,
      abi: mixed_abi
    )

    calls_per_chain = Hash.new(0)
    spy = lambda do |chain:, calls:|
      calls_per_chain[chain.slug] += 1
      calls.map { ChainReader::Multicall3Client::Result.new(success: true, values: [ 0 ]) }
    end

    stub_class_method(ChainReader::Multicall3Client, :call, spy) do
      ChainReader::ViewCaller.call(eth_contract)
      ChainReader::ViewCaller.call(base_contract)
      ChainReader::ViewCaller.call(eth_contract)   # cached
      ChainReader::ViewCaller.call(base_contract)  # cached
    end

    assert_equal 1, calls_per_chain["eth"]
    assert_equal 1, calls_per_chain["base"]
  end

  test "fallback swallows individual eth_call failures into per-function error Results" do
    raising_multicall = ->(chain:, calls:) { raise ChainReader::Base::RpcError, "multicall failed" }
    raising_single = ->(_chain, to:, data:) { raise ChainReader::Base::RpcError, "single call failed too" }

    stub_class_method(ChainReader::Multicall3Client, :call, raising_multicall) do
      stub_class_method(ChainReader::Base, :eth_call_hex, raising_single) do
        results = ChainReader::ViewCaller.call(@contract)

        assert_equal 2, results.size
        assert(results.values.none?(&:success), "all results should be marked failed")
        assert(results.values.all? { |r| r.error.to_s.include?("single call failed") })
      end
    end
  end

  test "Snapshot carries block_number from the underlying Multicall3 batch" do
    captured_block = 24_000_000
    spy = lambda do |chain:, calls:|
      ChainReader::Multicall3Client::Batch.new(
        block_number: captured_block,
        results: calls.map { ChainReader::Multicall3Client::Result.new(success: true, values: [ 0 ]) }
      )
    end

    stub_class_method(ChainReader::Multicall3Client, :call, spy) do
      before = Time.current
      snapshot = ChainReader::ViewCaller.call(@contract)
      after  = Time.current

      assert_equal captured_block, snapshot.block_number,
                   "Snapshot.block_number must reflect the batch we read at"
      assert_kind_of Time, snapshot.fetched_at
      assert snapshot.fetched_at >= before && snapshot.fetched_at <= after
    end
  end

  test "fallback path captures block_number via eth_blockNumber when multicall fails" do
    fallback_block = 19_500_000
    raising = ->(chain:, calls:) { raise ChainReader::Base::RpcError, "multicall failed" }

    name_hex = "0x" + Eth::Abi.encode([ "string" ], [ "Uniswap" ]).unpack1("H*")
    supply_hex = "0x" + Eth::Abi.encode([ "uint256" ], [ 42 ]).unpack1("H*")
    single_stub = lambda do |_c, to:, data:|
      case data[0, 10]
      when ChainReader::Base.selector("name()") then name_hex
      when ChainReader::Base.selector("totalSupply()") then supply_hex
      end
    end

    stub_class_method(ChainReader::Multicall3Client, :call, raising) do
      stub_class_method(ChainReader::Base, :eth_call_hex, single_stub) do
        stub_class_method(ChainReader::Base, :eth_block_number, ->(_c) { fallback_block }) do
          snapshot = ChainReader::ViewCaller.call(@contract)
          assert_equal fallback_block, snapshot.block_number,
                       "fallback must read a fresh block_number, not leave it nil"
        end
      end
    end
  end

  test "fallback path leaves block_number nil if eth_blockNumber also fails" do
    raising_multicall = ->(chain:, calls:) { raise ChainReader::Base::RpcError, "multicall down" }
    raising_block     = ->(_c) { raise ChainReader::Base::RpcError, "block_number down too" }
    raising_single    = ->(_c, to:, data:) { raise ChainReader::Base::RpcError, "single failed" }

    stub_class_method(ChainReader::Multicall3Client, :call, raising_multicall) do
      stub_class_method(ChainReader::Base, :eth_call_hex, raising_single) do
        stub_class_method(ChainReader::Base, :eth_block_number, raising_block) do
          snapshot = ChainReader::ViewCaller.call(@contract)
          assert_nil snapshot.block_number,
                     "double-failure must yield nil block_number, not crash the page"
        end
      end
    end
  end

  test "returns empty Snapshot when contract has no zero-arg view functions" do
    contract = build_contract_with_abi([
      { "type" => "function", "name" => "balanceOf",
        "inputs" => [ { "type" => "address" } ],
        "outputs" => [ { "type" => "uint256" } ],
        "stateMutability" => "view" }
    ])

    refused = lambda do |**_kwargs|
      flunk "Multicall3Client should not be called when there are no zero-arg view functions"
    end

    stub_class_method(ChainReader::Multicall3Client, :call, refused) do
      snapshot = ChainReader::ViewCaller.call(contract)
      assert_kind_of ChainReader::ViewCaller::Snapshot, snapshot
      assert_empty snapshot
      assert_nil snapshot.block_number
    end
  end

  private

  def mixed_abi
    [
      { "type" => "function", "name" => "name", "inputs" => [],
        "outputs" => [ { "type" => "string" } ], "stateMutability" => "view" },
      { "type" => "function", "name" => "totalSupply", "inputs" => [],
        "outputs" => [ { "type" => "uint256" } ], "stateMutability" => "view" },
      { "type" => "function", "name" => "balanceOf",
        "inputs" => [ { "type" => "address" } ],
        "outputs" => [ { "type" => "uint256" } ], "stateMutability" => "view" },
      { "type" => "function", "name" => "transfer",
        "inputs" => [ { "type" => "address" }, { "type" => "uint256" } ],
        "outputs" => [ { "type" => "bool" } ], "stateMutability" => "nonpayable" }
    ]
  end

  def build_contract_with_abi(abi)
    Contract.create!(
      chain: @chain,
      address: "0x" + SecureRandom.hex(20),
      abi: abi
    )
  end

  def stub_multicall_success_returning(value, &block)
    stub = lambda do |chain:, calls:|
      calls.map { ChainReader::Multicall3Client::Result.new(success: true, values: [ value ]) }
    end
    stub_class_method(ChainReader::Multicall3Client, :call, stub, &block)
  end
end
