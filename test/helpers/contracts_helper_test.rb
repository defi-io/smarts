require "test_helper"
require "ostruct"

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

  test "format_abi_output renders tuple with component names inline" do
    tuple_value = [ 1_000_000_000, "0xabc", true ]
    output = {
      "type" => "tuple",
      "components" => [
        { "name" => "liquidity", "type" => "uint256" },
        { "name" => "addr",      "type" => "address" },
        { "name" => "unlocked",  "type" => "bool" }
      ]
    }

    assert_equal "(liquidity: 1,000,000,000, addr: 0xabc, unlocked: true)",
                 format_abi_output(tuple_value, output)
  end

  test "format_abi_output renders unnamed tuple components without labels" do
    output = {
      "type" => "tuple",
      "components" => [ { "type" => "uint256" }, { "type" => "uint256" } ]
    }
    assert_equal "(1,000, 2,000)", format_abi_output([ 1_000, 2_000 ], output)
  end

  test "format_abi_output handles arrays of tuples" do
    output = {
      "type" => "tuple[]",
      "components" => [
        { "name" => "a", "type" => "uint256" },
        { "name" => "b", "type" => "uint256" }
      ]
    }
    assert_equal "[(a: 1, b: 2), (a: 3, b: 4)]",
                 format_abi_output([ [ 1, 2 ], [ 3, 4 ] ], output)
  end

  test "format_abi_output passes through scalars to format_abi_value" do
    assert_equal "1,000,000", format_abi_output(1_000_000, { "type" => "uint256" })
    assert_equal "true", format_abi_output(true, { "type" => "bool" })
  end

  test "render_live_result formats tuple return value with component names" do
    result = ChainReader::Multicall3Client::Result.new(
      success: true,
      values: [ [ 7919111111111, -42, true ] ]
    )
    fn = {
      "outputs" => [ {
        "type" => "tuple",
        "components" => [
          { "name" => "sqrtPriceX96", "type" => "uint160" },
          { "name" => "tick",         "type" => "int24" },
          { "name" => "unlocked",     "type" => "bool" }
        ]
      } ]
    }

    html = render_live_result(result, fn)
    assert_includes html, "sqrtPriceX96: 7,919,111,111,111"
    assert_includes html, "tick: -42"
    assert_includes html, "unlocked: true"
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

  test "ai_badge renders only when source is ai" do
    assert_includes ai_badge("ai").to_s, "✨ AI"
    assert_nil ai_badge("real")
    assert_nil ai_badge(nil)
  end

  test "ai_badge is html_safe and carries a tooltip" do
    html = ai_badge("ai")
    assert html.html_safe?
    assert_match(/title=/, html)
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

  # ---------- smart_format_output: ERC-20 decimals scaling ----------

  def erc20_live_values(decimals:, symbol:)
    {
      "decimals()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ decimals ]),
      "symbol()"   => ChainReader::Multicall3Client::Result.new(success: true, values: [ symbol ])
    }
  end

  test "smart_format_output scales totalSupply for ERC-20 contracts using decimals() and symbol()" do
    @classification = OpenStruct.new(protocol_key: "erc20")
    @live_values = erc20_live_values(decimals: 6, symbol: "USDC")
    fn = { "name" => "totalSupply", "outputs" => [ { "type" => "uint256" } ] }

    assert_equal "55,046,395,721.80 USDC",
                 smart_format_output(55_046_395_721_805_492, fn["outputs"][0], fn)
  end

  test "smart_format_output strips fractional part when scaled value is whole" do
    @classification = OpenStruct.new(protocol_key: "erc20")
    @live_values = erc20_live_values(decimals: 18, symbol: "DAI")
    fn = { "name" => "totalSupply", "outputs" => [ { "type" => "uint256" } ] }

    # 1_000 DAI exactly → 1e21 wei → "1,000 DAI", no trailing .00
    assert_equal "1,000 DAI", smart_format_output(1_000 * 10**18, fn["outputs"][0], fn)
  end

  test "smart_format_output falls back to raw when classification is not erc20" do
    @classification = OpenStruct.new(protocol_key: "uniswap_v3_pool")
    @live_values = erc20_live_values(decimals: 6, symbol: "USDC")
    fn = { "name" => "totalSupply", "outputs" => [ { "type" => "uint256" } ] }

    assert_equal "55,046,395,721,805,492",
                 smart_format_output(55_046_395_721_805_492, fn["outputs"][0], fn)
  end

  test "smart_format_output falls back to raw for non-totalSupply functions even on ERC-20" do
    @classification = OpenStruct.new(protocol_key: "erc20")
    @live_values = erc20_live_values(decimals: 6, symbol: "USDC")
    fn = { "name" => "nonce", "outputs" => [ { "type" => "uint256" } ] }

    assert_equal "42", smart_format_output(42, fn["outputs"][0], fn)
  end

  test "smart_format_output falls back to raw when decimals() live value is missing" do
    @classification = OpenStruct.new(protocol_key: "erc20")
    @live_values = {
      "symbol()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ])
      # no decimals()
    }
    fn = { "name" => "totalSupply", "outputs" => [ { "type" => "uint256" } ] }

    assert_equal "55,046,395,721,805,492",
                 smart_format_output(55_046_395_721_805_492, fn["outputs"][0], fn)
  end

  test "smart_format_output omits symbol suffix when symbol() live value is missing" do
    @classification = OpenStruct.new(protocol_key: "erc20")
    @live_values = {
      "decimals()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ 6 ])
    }
    fn = { "name" => "totalSupply", "outputs" => [ { "type" => "uint256" } ] }

    assert_equal "55,046,395,721.80",
                 smart_format_output(55_046_395_721_805_492, fn["outputs"][0], fn)
  end

  test "render_live_result decimals-scales totalSupply for ERC-20 contracts" do
    @classification = OpenStruct.new(protocol_key: "erc20")
    @live_values = erc20_live_values(decimals: 6, symbol: "USDC")
    result = ChainReader::Multicall3Client::Result.new(success: true, values: [ 55_046_395_721_805_492 ])
    fn = { "name" => "totalSupply", "outputs" => [ { "type" => "uint256" } ] }

    html = render_live_result(result, fn)
    assert_includes html, "55,046,395,721.80 USDC"
    refute_includes html, "55,046,395,721,805,492"
  end

  # ---------- contract_display_name ----------

  test "contract_display_name prefers on-chain name() over contract.name" do
    @contract = OpenStruct.new(name: "FiatTokenV2_2")
    @live_values = {
      "name()"   => ChainReader::Multicall3Client::Result.new(success: true, values: [ "USD Coin" ]),
      "symbol()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ])
    }
    assert_equal "USD Coin", contract_display_name
  end

  test "contract_display_name falls back to symbol() when on-chain name() is missing" do
    @contract = OpenStruct.new(name: "FiatTokenV2_2")
    @live_values = {
      "symbol()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ])
    }
    assert_equal "USDC", contract_display_name
  end

  test "contract_display_name falls back to contract.name when neither on-chain call is available" do
    @contract = OpenStruct.new(name: "FiatTokenV2_2")
    @live_values = {}
    assert_equal "FiatTokenV2_2", contract_display_name
  end

  test "contract_display_name returns 'Unknown Contract' when everything is empty" do
    @contract = OpenStruct.new(name: nil)
    @live_values = {}
    assert_equal "Unknown Contract", contract_display_name
  end

  test "contract_display_name ignores reverted on-chain calls" do
    @contract = OpenStruct.new(name: "FiatTokenV2_2")
    @live_values = {
      "name()"   => ChainReader::Multicall3Client::Result.new(success: false, error: "reverted"),
      "symbol()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ])
    }
    assert_equal "USDC", contract_display_name
  end

  test "contract_display_name treats empty-string on-chain values as absent" do
    @contract = OpenStruct.new(name: "FiatTokenV2_2")
    @live_values = {
      "name()"   => ChainReader::Multicall3Client::Result.new(success: true, values: [ "" ]),
      "symbol()" => ChainReader::Multicall3Client::Result.new(success: true, values: [ "USDC" ])
    }
    assert_equal "USDC", contract_display_name
  end

  test "contract_display_name is nil-safe when @live_values is nil" do
    @contract = OpenStruct.new(name: "FiatTokenV2_2")
    @live_values = nil
    assert_equal "FiatTokenV2_2", contract_display_name
  end

  # ---------- explorer_address_url / explorer_name / truncate_address ----------

  test "explorer_address_url maps supported chain slugs to their block explorer" do
    eth      = OpenStruct.new(slug: "eth")
    base     = OpenStruct.new(slug: "base")
    arbitrum = OpenStruct.new(slug: "arbitrum")
    optimism = OpenStruct.new(slug: "optimism")
    polygon  = OpenStruct.new(slug: "polygon")

    assert_equal "https://etherscan.io/address/0xabc",            explorer_address_url(eth,      "0xabc")
    assert_equal "https://basescan.org/address/0xabc",            explorer_address_url(base,     "0xabc")
    assert_equal "https://arbiscan.io/address/0xabc",             explorer_address_url(arbitrum, "0xabc")
    assert_equal "https://optimistic.etherscan.io/address/0xabc", explorer_address_url(optimism, "0xabc")
    assert_equal "https://polygonscan.com/address/0xabc",         explorer_address_url(polygon,  "0xabc")
  end

  test "explorer_address_url returns nil for unknown chain slug" do
    assert_nil explorer_address_url(OpenStruct.new(slug: "solana"), "0xabc")
  end

  test "explorer_name returns the human explorer name per chain" do
    assert_equal "Etherscan",   explorer_name(OpenStruct.new(slug: "eth"))
    assert_equal "Basescan",    explorer_name(OpenStruct.new(slug: "base"))
    assert_equal "Arbiscan",    explorer_name(OpenStruct.new(slug: "arbitrum"))
    assert_equal "Etherscan",   explorer_name(OpenStruct.new(slug: "optimism"))
    assert_equal "Polygonscan", explorer_name(OpenStruct.new(slug: "polygon"))
    assert_equal "explorer",    explorer_name(OpenStruct.new(slug: "zzz"))
  end

  test "truncate_address shortens long 0x addresses to 6+4 with ellipsis" do
    assert_equal "0xa0b8…eb48", truncate_address("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
  end

  test "truncate_address returns nil for non-strings or malformed input" do
    assert_nil truncate_address(nil)
    assert_nil truncate_address(42)
    assert_nil truncate_address("0xabc") # too short to truncate meaningfully
  end

  # ---------- format_native_balance / _precise ----------

  test "format_native_balance renders 2dp and strips trailing .00" do
    # 1.8 ETH exactly
    assert_equal "1.80 ETH", format_native_balance(BigDecimal("1.8") * BigDecimal("1e18"), "ETH")
    # whole number, should drop .00
    assert_equal "1,000 ETH", format_native_balance(1_000 * 10**18, "ETH")
    # sub-cent rounds DOWN, not up
    assert_equal "0 ETH", format_native_balance(9_000_000_000_000_000, "ETH") # 0.009 ETH
  end

  test "format_native_balance returns nil for nil input" do
    assert_nil format_native_balance(nil, "ETH")
  end

  test "format_native_balance_precise renders 6dp padded" do
    assert_equal "1.800000 ETH", format_native_balance_precise(BigDecimal("1.8") * BigDecimal("1e18"), "ETH")
    assert_equal "0.009000 ETH", format_native_balance_precise(9_000_000_000_000_000, "ETH")
    assert_equal "1,000.000000 ETH", format_native_balance_precise(1_000 * 10**18, "ETH")
  end

  test "format_native_balance handles MATIC symbol" do
    assert_equal "5.50 MATIC", format_native_balance(BigDecimal("5.5") * BigDecimal("1e18"), "MATIC")
  end
end
