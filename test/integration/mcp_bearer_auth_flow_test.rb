require "test_helper"

# End-to-end check that an `Authorization: Bearer <publish_token>` header
# on a POST to /mcp authenticates the publisher and reaches the article
# tool with `Current.mcp_user` populated. Exercises the real Rack stack:
# Rails middleware → McpBearerAuth → MCP transport → tool dispatch.
class McpBearerAuthFlowTest < ActionDispatch::IntegrationTest
  test "list_article_drafts succeeds with valid Bearer token" do
    Dir.mktmpdir do |dir|
      draft_dir = Pathname(dir).join("ms")
      FileUtils.mkdir_p(draft_dir)
      draft_dir.join("meta.json").write({
        category: "company",
        title: { "zh-CN" => "Test draft" }
      }.to_json)
      draft_dir.join("zh-CN.md").write("# Test draft\n\nBody")

      original = Articles::DraftReader.method(:list_summaries)
      stub_class_method(Articles::DraftReader, :list_summaries, ->(**) {
        original.call(drafts_root: dir)
      }) do
        body = post_mcp(
          method: "tools/call",
          params: { name: "list_article_drafts", arguments: {} },
          bearer: "sma_test_token_one"
        )

        assert_response :success

        payload = JSON.parse(body.dig("result", "content", 0, "text"))
        assert_kind_of Integer, payload["count"]
        assert_operator payload["count"], :>=, 1
        assert(payload["drafts"].any? { |d| d["slug"] == "ms" })
      end
    end
  end

  test "list_article_drafts returns auth error without Bearer token" do
    body = post_mcp(
      method: "tools/call",
      params: { name: "list_article_drafts", arguments: {} },
      bearer: nil
    )

    payload = JSON.parse(body.dig("result", "content", 0, "text"))
    assert_equal "Authorization: Bearer <publish_token> header is missing or invalid", payload["error"]
  end

  test "list_article_drafts returns auth error with invalid Bearer token" do
    body = post_mcp(
      method: "tools/call",
      params: { name: "list_article_drafts", arguments: {} },
      bearer: "bogus"
    )

    payload = JSON.parse(body.dig("result", "content", 0, "text"))
    assert_equal "Authorization: Bearer <publish_token> header is missing or invalid", payload["error"]
  end

  test "production MCP hosts pass the transport's Host check" do
    %w[smarts.md mcp.smarts.md].each do |production_host|
      host! production_host
      body = post_mcp(method: "tools/list", params: {}, bearer: nil)

      assert_response :success, "#{production_host} was rejected: #{body.inspect}"
      assert body.dig("result", "tools").any?
    end
  end

  test "unknown Host is rejected by the transport" do
    host! "evil.example"
    body = post_mcp(method: "tools/list", params: {}, bearer: nil)

    assert_response :forbidden
    assert_equal "Forbidden: Invalid Host header", body.dig("error", "message")
  end

  test "tools/list advertises the Aave and DefiLlama tools" do
    body = post_mcp(method: "tools/list", params: {}, bearer: nil)
    names = body.dig("result", "tools").map { |t| t["name"] }
    %w[get_aave_v3_market get_stablecoin_supply get_protocol_tvl get_yield_pools find_uniswap_v3_pools quote_uniswap_v3_swap].each { |tool| assert_includes names, tool }
  end

  private

  # POSTs a single JSON-RPC message to the MCP endpoint and parses the
  # JSON-RPC envelope. Returns the parsed Hash body.
  def post_mcp(method:, params:, bearer:)
    headers = {
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
    headers["Authorization"] = "Bearer #{bearer}" if bearer

    payload = { jsonrpc: "2.0", id: 1, method: method, params: params }

    post "/mcp", params: payload.to_json, headers: headers
    JSON.parse(response.body)
  end
end
