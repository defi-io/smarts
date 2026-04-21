require "test_helper"

class ContractsHelperTest < ActionView::TestCase
  test "format_abi_value formats uint with thousands separators" do
    assert_equal "1,000,000", format_abi_value(1_000_000, "uint256")
    assert_equal "18", format_abi_value(18, "uint8")
    assert_equal "0", format_abi_value(0, "uint256")
  end

  test "format_abi_value formats int* same as uint" do
    assert_equal "-1,234,567", format_abi_value(-1_234_567, "int256")
  end

  test "format_abi_value renders bool" do
    assert_equal "true", format_abi_value(true, "bool")
    assert_equal "false", format_abi_value(false, "bool")
  end

  test "format_abi_value lowercases address" do
    assert_equal "0xdeadbeef", format_abi_value("0xDeAdBeEf", "address")
  end

  test "format_abi_value truncates long strings" do
    short = "hello"
    assert_equal "hello", format_abi_value(short, "string")

    long = "x" * 100
    formatted = format_abi_value(long, "string")
    assert formatted.end_with?("..."), "long strings should be truncated with ellipsis"
    assert formatted.length <= 80
  end

  test "format_abi_value converts bytes to hex" do
    bytes = [ 0xca, 0xfe, 0xba, 0xbe ].pack("C*")
    assert_equal "0xcafebabe", format_abi_value(bytes, "bytes32")
    assert_equal "0xcafebabe", format_abi_value(bytes, "bytes")
  end

  test "format_abi_value renders arrays inline" do
    assert_equal "[1, 2, 3]", format_abi_value([ 1, 2, 3 ], "uint256[]")
  end

  test "format_abi_value handles nested arrays" do
    assert_equal "[[1, 2], [3]]", format_abi_value([ [ 1, 2 ], [ 3 ] ], "uint256[][]")
  end

  test "format_abi_value falls back to inspect for tuple types (current limitation)" do
    # Tuples (Solidity structs) decode to arrays. We don't have per-component
    # formatting yet, so fall through to inspect. Test documents this so tuple
    # support later has a signal when it lands.
    tuple_value = [ 1_000_000_000, "0xabc", true ]
    formatted = format_abi_value(tuple_value, "tuple")
    assert_equal tuple_value.inspect, formatted
  end

  test "render_live_result returns nil when result is nil" do
    assert_nil render_live_result(nil, { "outputs" => [ { "type" => "uint256" } ] })
  end

  test "render_live_result renders success value with arrow and success styling" do
    result = ChainReader::Multicall3Client::Result.new(success: true, values: [ 42 ])
    fn = { "outputs" => [ { "type" => "uint256" } ] }

    html = render_live_result(result, fn)
    assert_includes html, "→"
    assert_includes html, "42"
    assert_includes html, "text-success"
  end

  test "render_live_result renders 'reverted' badge on failure" do
    result = ChainReader::Multicall3Client::Result.new(success: false, error: "execution reverted")
    fn = { "outputs" => [ { "type" => "uint256" } ] }

    html = render_live_result(result, fn)
    assert_includes html, "reverted"
    assert_includes html, "text-error"
  end

  test "render_live_result returns nil when outputs list is empty" do
    result = ChainReader::Multicall3Client::Result.new(success: true, values: [])
    fn = { "outputs" => [] }

    assert_nil render_live_result(result, fn)
  end

  test "render_live_result joins multi-return values with commas" do
    result = ChainReader::Multicall3Client::Result.new(success: true, values: [ 1, 2 ])
    fn = { "outputs" => [ { "type" => "uint256" }, { "type" => "uint256" } ] }

    html = render_live_result(result, fn)
    assert_includes html, "1, 2"
  end

  test "function_signature_with_params renders zero-arg as bare parens" do
    fn = { "name" => "totalSupply", "inputs" => [] }
    assert_equal "totalSupply()", function_signature_with_params(fn)
  end

  test "function_signature_with_params includes named parameters" do
    fn = {
      "name" => "transfer",
      "inputs" => [
        { "name" => "to", "type" => "address" },
        { "name" => "amount", "type" => "uint256" }
      ]
    }
    assert_equal "transfer(to: address, amount: uint256)", function_signature_with_params(fn)
  end

  test "function_signature_with_params omits empty names" do
    fn = {
      "name" => "mixed",
      "inputs" => [
        { "name" => "", "type" => "address" },
        { "name" => "amount", "type" => "uint256" }
      ]
    }
    assert_equal "mixed(address, amount: uint256)", function_signature_with_params(fn)
  end
end
