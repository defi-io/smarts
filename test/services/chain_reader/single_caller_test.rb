require "test_helper"

class ChainReader::SingleCallerTest < ActiveSupport::TestCase
  setup do
    @chain = chains(:ethereum)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "raises FunctionNotFound for an unknown function name" do
    contract = build_contract(abi_totalSupply)
    assert_raises(ChainReader::SingleCaller::FunctionNotFound) do
      ChainReader::SingleCaller.call(contract: contract, function_name: "bogus")
    end
  end

  test "raises FunctionNotFound when no overload matches the given arg count" do
    contract = build_contract(abi_with_overloads)
    assert_raises(ChainReader::SingleCaller::FunctionNotFound) do
      ChainReader::SingleCaller.call(contract: contract, function_name: "foo", args: [ 1, 2, 3 ])
    end
  end

  test "decodes a zero-arg view function result" do
    contract = build_contract(abi_totalSupply)
    hex = "0x" + Eth::Abi.encode([ "uint256" ], [ 42_000 ]).unpack1("H*")

    stub_class_method(ChainReader::Base, :eth_call_hex, ->(_c, **_) { hex }) do
      r = ChainReader::SingleCaller.call(contract: contract, function_name: "totalSupply")
      assert r.success
      assert_equal [ 42_000 ], r.values
      assert_equal 42_000, r.value
    end
  end

  test "encodes and sends args correctly for a function that takes arguments" do
    contract = build_contract([ abi_fn("balanceOf", inputs: [ "address" ], outputs: [ "uint256" ]) ])
    hex = "0x" + Eth::Abi.encode([ "uint256" ], [ 500 ]).unpack1("H*")

    captured = {}
    stub_class_method(ChainReader::Base, :eth_call_hex, ->(_c, to:, data:) { captured[:data] = data; hex }) do
      r = ChainReader::SingleCaller.call(
        contract: contract,
        function_name: "balanceOf",
        args: [ "0x0000000000000000000000000000000000000001" ]
      )
      assert_equal [ 500 ], r.values
    end

    bal_selector = ChainReader::Base.selector("balanceOf(address)")
    assert captured[:data].start_with?(bal_selector), "data should start with balanceOf selector"
    assert_includes captured[:data], "0" * 63 + "1", "address arg should be padded to 32 bytes"
  end

  test "caches results for 60s (same call doesn't re-hit RPC)" do
    contract = build_contract(abi_totalSupply)
    hex = "0x" + Eth::Abi.encode([ "uint256" ], [ 1 ]).unpack1("H*")

    invocations = 0
    stub_class_method(ChainReader::Base, :eth_call_hex, ->(_c, **_) { invocations += 1; hex }) do
      3.times { ChainReader::SingleCaller.call(contract: contract, function_name: "totalSupply") }
    end

    assert_equal 1, invocations
  end

  test "picks the overload variant matching the supplied arg count" do
    contract = build_contract(abi_with_overloads)
    # foo(uint)      → takes 1 arg, returns 1
    # foo(uint,uint) → takes 2 args, returns 2
    # Stub eth_call_hex to return a distinct value so we know which one ran.
    captured_selector = nil
    stub = lambda do |_c, to:, data:|
      captured_selector = data[0, 10]
      "0x" + Eth::Abi.encode([ "uint256" ], [ captured_selector == ChainReader::Base.selector("foo(uint256)") ? 1 : 2 ]).unpack1("H*")
    end

    stub_class_method(ChainReader::Base, :eth_call_hex, stub) do
      r = ChainReader::SingleCaller.call(contract: contract, function_name: "foo", args: [ 0 ])
      assert_equal [ 1 ], r.values
      assert_equal ChainReader::Base.selector("foo(uint256)"), captured_selector

      # Reset the cache so the second variant runs
      Rails.cache.clear
      r2 = ChainReader::SingleCaller.call(contract: contract, function_name: "foo", args: [ 0, 0 ])
      assert_equal [ 2 ], r2.values
      assert_equal ChainReader::Base.selector("foo(uint256,uint256)"), captured_selector
    end
  end

  test "decodes tuple-output functions end-to-end via abi_type_string" do
    tuple_fn = {
      "type" => "function", "name" => "slot0", "inputs" => [],
      "outputs" => [ {
        "type" => "tuple",
        "components" => [
          { "name" => "sqrtPriceX96", "type" => "uint160" },
          { "name" => "tick",         "type" => "int24" },
          { "name" => "unlocked",     "type" => "bool" }
        ]
      } ],
      "stateMutability" => "view"
    }
    contract = build_contract([ tuple_fn ])
    hex = "0x" + Eth::Abi.encode([ "(uint160,int24,bool)" ], [ [ 7_919_111, -42, true ] ]).unpack1("H*")

    stub_class_method(ChainReader::Base, :eth_call_hex, ->(_c, **_) { hex }) do
      r = ChainReader::SingleCaller.call(contract: contract, function_name: "slot0")
      assert r.success
      assert_equal [ [ 7_919_111, -42, true ] ], r.values
    end
  end

  test "returns success=false when RPC errors out" do
    contract = build_contract(abi_totalSupply)

    stub_class_method(ChainReader::Base, :eth_call_hex, ->(_c, **_) { raise ChainReader::Base::RpcError, "revert" }) do
      r = ChainReader::SingleCaller.call(contract: contract, function_name: "totalSupply")
      refute r.success
      assert_match(/revert/, r.error)
    end
  end

  private

  def abi_fn(name, inputs: [], outputs: [], mutability: "view")
    {
      "type" => "function",
      "name" => name,
      "inputs" => inputs.map { |t| { "type" => t } },
      "outputs" => outputs.map { |t| { "type" => t } },
      "stateMutability" => mutability
    }
  end

  def abi_totalSupply
    [ abi_fn("totalSupply", outputs: [ "uint256" ]) ]
  end

  def abi_with_overloads
    [
      abi_fn("foo", inputs: [ "uint256" ], outputs: [ "uint256" ]),
      abi_fn("foo", inputs: [ "uint256", "uint256" ], outputs: [ "uint256" ])
    ]
  end

  def build_contract(abi)
    Contract.create!(chain: @chain, address: "0x" + SecureRandom.hex(20), abi: abi)
  end
end
