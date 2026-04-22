require "test_helper"

class ChainReader::BaseTest < ActiveSupport::TestCase
  setup do
    @chain = chains(:ethereum)
  end

  test "selector computes 4-byte function selector" do
    assert_equal "0x18160ddd", ChainReader::Base.selector("totalSupply()")
    assert_equal "0x70a08231", ChainReader::Base.selector("balanceOf(address)")
    assert_equal "0xa9059cbb", ChainReader::Base.selector("transfer(address,uint256)")
  end

  test "function_signature joins name + input types" do
    fn = { "name" => "balanceOf", "inputs" => [ { "type" => "address" } ] }
    assert_equal "balanceOf(address)", ChainReader::Base.function_signature(fn)
  end

  test "function_signature handles zero-arg functions" do
    fn = { "name" => "totalSupply", "inputs" => [] }
    assert_equal "totalSupply()", ChainReader::Base.function_signature(fn)
  end

  test "function_signature tolerates missing inputs key" do
    fn = { "name" => "name" }
    assert_equal "name()", ChainReader::Base.function_signature(fn)
  end

  test "abi_type_string returns scalar types unchanged" do
    assert_equal "uint256", ChainReader::Base.abi_type_string({ "type" => "uint256" })
    assert_equal "address[]", ChainReader::Base.abi_type_string({ "type" => "address[]" })
  end

  test "abi_type_string expands tuple using components" do
    output = {
      "type" => "tuple",
      "components" => [
        { "type" => "uint160" },
        { "type" => "int24" },
        { "type" => "bool" }
      ]
    }
    assert_equal "(uint160,int24,bool)", ChainReader::Base.abi_type_string(output)
  end

  test "abi_type_string expands tuple arrays preserving suffix" do
    output = {
      "type" => "tuple[]",
      "components" => [ { "type" => "uint256" }, { "type" => "address" } ]
    }
    assert_equal "(uint256,address)[]", ChainReader::Base.abi_type_string(output)
  end

  test "abi_type_string handles nested tuples" do
    output = {
      "type" => "tuple",
      "components" => [
        { "type" => "uint256" },
        {
          "type" => "tuple",
          "components" => [ { "type" => "address" }, { "type" => "uint256" } ]
        }
      ]
    }
    assert_equal "(uint256,(address,uint256))", ChainReader::Base.abi_type_string(output)
  end

  test "hex_to_bytes strips 0x prefix and packs hex" do
    assert_equal "\x12\x34".b, ChainReader::Base.hex_to_bytes("0x1234")
    assert_equal "\x12\x34".b, ChainReader::Base.hex_to_bytes("1234")
  end

  test "eth_call_hex extracts result from JSON-RPC response hash" do
    fake = FakeRpcClient.new({ "jsonrpc" => "2.0", "id" => 1, "result" => "0xdeadbeef" })
    stub_class_method(ChainReader::Base, :client_for, ->(_chain) { fake }) do
      out = ChainReader::Base.eth_call_hex(@chain, to: "0xabc", data: "0x123")
      assert_equal "0xdeadbeef", out
    end
  end

  test "eth_call_hex raises RpcError on error field" do
    fake = FakeRpcClient.new({ "error" => { "code" => -32000, "message" => "missing trie node" } })
    stub_class_method(ChainReader::Base, :client_for, ->(_chain) { fake }) do
      err = assert_raises(ChainReader::Base::RpcError) do
        ChainReader::Base.eth_call_hex(@chain, to: "0xabc", data: "0x123")
      end
      assert_match(/-32000/, err.message)
      assert_match(/missing trie node/, err.message)
    end
  end

  test "eth_call_hex accepts raw string response (non-hash client)" do
    fake = FakeRpcClient.new("0xcafe")
    stub_class_method(ChainReader::Base, :client_for, ->(_chain) { fake }) do
      assert_equal "0xcafe", ChainReader::Base.eth_call_hex(@chain, to: "0xabc", data: "0x123")
    end
  end

  # ---------- retag_string_encoding ----------

  test "retag_string_encoding promotes ASCII-8BIT UTF-8 bytes to UTF-8 for string outputs" do
    # "USD₮0" — the ₮ glyph (U+20AE) is 3 UTF-8 bytes. The eth gem's ABI
    # decoder tags such strings as ASCII-8BIT, which collides with UTF-8
    # literals in ERB (e.g. ↗) at render time. retag_string_encoding should
    # re-label them as UTF-8 without changing bytes.
    raw_bytes = "USD\xE2\x82\xAE0".b
    assert_equal Encoding::ASCII_8BIT, raw_bytes.encoding

    result = ChainReader::Base.retag_string_encoding(raw_bytes, { "type" => "string" })
    assert_equal Encoding::UTF_8, result.encoding
    assert_equal "USD₮0", result
  end

  test "retag_string_encoding leaves non-string types untouched" do
    raw_bytes = "\x12\x34".b
    assert_equal raw_bytes, ChainReader::Base.retag_string_encoding(raw_bytes, { "type" => "bytes32" })
    assert_equal 42, ChainReader::Base.retag_string_encoding(42, { "type" => "uint256" })
  end

  test "retag_string_encoding leaves strings already tagged UTF-8 alone" do
    already = "hello"
    assert_same already, ChainReader::Base.retag_string_encoding(already, { "type" => "string" })
  end

  test "retag_string_encoding returns the original string when bytes aren't valid UTF-8" do
    invalid = "\xFF\xFE".b
    result = ChainReader::Base.retag_string_encoding(invalid, { "type" => "string" })
    assert_equal Encoding::ASCII_8BIT, result.encoding, "mustn't silently mis-tag garbage"
  end

  class FakeRpcClient
    def initialize(response)
      @response = response
    end

    def eth_call(_params)
      @response
    end
  end
end
