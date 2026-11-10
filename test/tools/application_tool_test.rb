require "test_helper"

class ApplicationToolTest < ActiveSupport::TestCase
  setup do
    @docs_chain = Chain.create!(
      name: "Linea", slug: "linea", chain_id: 59144,
      explorer_api_url: "https://api.etherscan.io/v2/api",
      tier: "docs_only"
    )
    @contract = contracts(:uni_token)
  end

  test "check_full_tier returns nil for full chains" do
    assert_nil ApplicationTool.check_full_tier(chains(:ethereum))
  end

  test "check_full_tier returns error hash for docs_only chains" do
    result = ApplicationTool.check_full_tier(@docs_chain)
    assert_match(/linea/, result[:error])
    assert_match(/docs-only/, result[:error])
    assert_match(/get_contract_info|get_contract_source/, result[:error])
  end

  test "resolve_contract with require_full: true rejects docs_only chains" do
    docs_contract = Contract.create!(
      chain: @docs_chain,
      address: "0x" + "1" * 40,
      name: "FakeToken"
    )
    result = ApplicationTool.resolve_contract(
      chain: "linea", address: docs_contract.address, require_full: true
    )
    assert result.is_a?(Hash)
    assert_match(/docs-only/, result[:error])
  end

  test "resolve_contract with require_full: false allows docs_only chains" do
    docs_contract = Contract.create!(
      chain: @docs_chain,
      address: "0x" + "2" * 40,
      name: "FakeToken"
    )
    result = ApplicationTool.resolve_contract(
      chain: "linea", address: docs_contract.address, require_full: false
    )
    assert result.is_a?(Array)
    assert_equal @docs_chain, result[0]
    assert_equal docs_contract, result[1]
  end

  test "resolve_contract with require_full: true still works on full chains" do
    result = ApplicationTool.resolve_contract(
      chain: "eth", address: @contract.address, require_full: true
    )
    assert result.is_a?(Array)
    assert_equal chains(:ethereum), result[0]
  end

  test "resolve_token accepts addresses and same-chain curated slugs" do
    assert_equal [ "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", nil ], ApplicationTool.resolve_token("eth", "0xA0b86991c6218b36c1d19d4a2e9eB0cE3606eB48")
    assert_equal [ "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", nil ], ApplicationTool.resolve_token("eth", "usdc-eth")
    assert_equal "usdc-eth is on eth, not base", ApplicationTool.resolve_token("base", "usdc-eth").last[:error]
    assert_match(/0x address or a curated slug/, ApplicationTool.resolve_token("eth", "USDC").last[:error])
  end

  test "text_response flags error payloads as MCP isError" do
    failed = ApplicationTool.text_response({ error: "unknown slug: nope-eth" }).to_h
    ok = ApplicationTool.text_response({ chain: "eth", error: nil }).to_h

    assert_equal true, failed[:isError]
    assert_equal false, ok[:isError]
    assert_equal({ "error" => "unknown slug: nope-eth" }, JSON.parse(failed[:content].first[:text]))
  end
end
