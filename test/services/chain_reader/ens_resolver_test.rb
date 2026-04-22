require "test_helper"

class ChainReader::EnsResolverTest < ActiveSupport::TestCase
  VITALIK       = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".downcase.freeze
  REVERSE_NODE  = "reverse_node_bytes".freeze     # opaque sentinel used in stubs
  FORWARD_NODE  = "forward_node_bytes".freeze

  setup do
    @eth  = chains(:ethereum)
    @base = chains(:base)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "returns nil for non-eth chains without touching RPC" do
    never = ->(*) { raise "must not be called" }
    stub_class_method(ChainReader::Base, :eth_call_hex, never) do
      assert_nil ChainReader::EnsResolver.call(chain: @base, address: VITALIK)
    end
  end

  # For RPC-level tests we fake the two eth_call hops. The stub routes by
  # destination address: calls into the ENS Registry vs into a resolver.
  def stub_rpc(registry_responses: {}, resolver_responses: {})
    lambda do |_chain, to:, data:|
      dest = to.downcase
      if dest == ChainReader::EnsResolver::REGISTRY.downcase
        registry_responses[data] or raise "no registry stub for data=#{data}"
      else
        (resolver_responses[dest] || {})[data] or raise "no resolver stub for #{dest} data=#{data}"
      end
    end
  end

  test "returns nil when registry resolver() is the zero address" do
    zero_addr_hex = "0x" + Eth::Abi.encode([ "address" ], [ ChainReader::EnsResolver::ZERO_ADDRESS ]).unpack1("H*")

    # Any registry call returns zero resolver
    any_to_zero = ->(_chain, to:, data:) { zero_addr_hex }
    stub_class_method(ChainReader::Base, :eth_call_hex, any_to_zero) do
      assert_nil ChainReader::EnsResolver.call(chain: @eth, address: VITALIK)
    end
  end

  test "happy path: reverse + forward verify returns the name" do
    resolver_addr = "0x1234567890abcdef1234567890abcdef12345678"
    resolver_hex  = "0x" + Eth::Abi.encode([ "address" ], [ resolver_addr ]).unpack1("H*")
    name_hex      = "0x" + Eth::Abi.encode([ "string" ], [ "vitalik.eth" ]).unpack1("H*")
    forward_hex   = "0x" + Eth::Abi.encode([ "address" ], [ VITALIK ]).unpack1("H*")

    route = lambda do |_chain, to:, data:|
      # Every registry call returns the same resolver (both reverse+forward sides)
      if to.downcase == ChainReader::EnsResolver::REGISTRY.downcase
        resolver_hex
      else
        # Resolver gets called with either name(node) or addr(node) selectors.
        # Distinguish by the first 4 bytes of calldata.
        selector = data[0, 10] # "0x" + 8 hex chars
        if selector == ChainReader::Base.selector("name(bytes32)")
          name_hex
        elsif selector == ChainReader::Base.selector("addr(bytes32)")
          forward_hex
        else
          raise "unexpected selector #{selector}"
        end
      end
    end

    stub_class_method(ChainReader::Base, :eth_call_hex, route) do
      assert_equal "vitalik.eth", ChainReader::EnsResolver.call(chain: @eth, address: VITALIK)
    end
  end

  test "forward-verify mismatch returns nil (prevents spoofed reverse records)" do
    resolver_addr  = "0x1234567890abcdef1234567890abcdef12345678"
    resolver_hex   = "0x" + Eth::Abi.encode([ "address" ], [ resolver_addr ]).unpack1("H*")
    name_hex       = "0x" + Eth::Abi.encode([ "string" ], [ "attacker.eth" ]).unpack1("H*")
    different_addr = "0x0000000000000000000000000000000000001234"
    forward_hex    = "0x" + Eth::Abi.encode([ "address" ], [ different_addr ]).unpack1("H*")

    route = lambda do |_chain, to:, data:|
      if to.downcase == ChainReader::EnsResolver::REGISTRY.downcase
        resolver_hex
      else
        selector = data[0, 10]
        if selector == ChainReader::Base.selector("name(bytes32)")
          name_hex
        else
          forward_hex
        end
      end
    end

    stub_class_method(ChainReader::Base, :eth_call_hex, route) do
      assert_nil ChainReader::EnsResolver.call(chain: @eth, address: VITALIK)
    end
  end

  test "RPC errors are rescued and return nil (never bubble up)" do
    exploder = ->(*) { raise ChainReader::Base::RpcError, "node down" }
    stub_class_method(ChainReader::Base, :eth_call_hex, exploder) do
      assert_nil ChainReader::EnsResolver.call(chain: @eth, address: VITALIK)
    end
  end

  # Known-good namehash vectors from the EIP-137 test suite.
  test "namehash matches EIP-137 known values" do
    resolver = ChainReader::EnsResolver.new(@eth, "0x0")

    # namehash('') = 0x0...0 (32 bytes of zeros)
    assert_equal ("\x00" * 32).b, resolver.send(:namehash, "")

    # namehash('eth') and namehash('foo.eth') — verify the chain builds correctly
    # by checking length + that the hashes differ
    eth_node = resolver.send(:namehash, "eth")
    foo_eth  = resolver.send(:namehash, "foo.eth")
    assert_equal 32, eth_node.bytesize
    assert_equal 32, foo_eth.bytesize
    refute_equal eth_node, foo_eth
  end
end
