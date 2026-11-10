# frozen_string_literal: true

require "test_helper"

class Api::V1::ToolsControllerTest < ActionDispatch::IntegrationTest
  test "returns 404 for unknown tool" do
    get api_v1_tool_path(tool_name: "nonexistent")
    assert_response :not_found
    assert_equal "unknown tool: nonexistent", response.parsed_body["error"]
  end

  test "get_erc20_info returns token data via slug" do
    stub = ->(**_kwargs) { { symbol: "USDC", name: "USD Coin", decimals: 6 } }
    stub_class_method(GetErc20InfoTool, :payload, stub) do
      get api_v1_tool_path(tool_name: "get_erc20_info", slug: "usdc-eth")
      assert_response :success
      body = response.parsed_body
      assert_equal "USDC", body["symbol"]
      assert_equal "USD Coin", body["name"]
    end
  end

  test "get_erc20_info returns token data via chain+address" do
    stub = ->(**_kwargs) { { symbol: "USDC", decimals: 6 } }
    stub_class_method(GetErc20InfoTool, :payload, stub) do
      get api_v1_tool_path(tool_name: "get_erc20_info", chain: "eth", address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
      assert_response :success
      assert_equal "USDC", response.parsed_body["symbol"]
    end
  end

  test "integer params are coerced correctly" do
    captured = {}
    stub = ->(**kwargs) { captured.merge!(kwargs); { events: [] } }
    stub_class_method(GetRecentEventsTool, :payload, stub) do
      get api_v1_tool_path(tool_name: "get_recent_events", slug: "usdc-eth", limit: "5")
      assert_response :success
      assert_equal 5, captured[:limit]
    end
  end

  test "CORS header is present on response" do
    stub = ->(**_kwargs) { { ok: true } }
    stub_class_method(InspectAddressTool, :payload, stub) do
      get api_v1_tool_path(tool_name: "inspect_address", chain: "eth", address: "0x0000000000000000000000000000000000000001")
      assert_response :success
    end
  end

  test "get_aave_v3_market is exposed over REST and forwards chain + asset" do
    seen = nil
    stub = ->(**kwargs) { seen = kwargs; { protocol: "Aave V3", chain: kwargs[:chain] } }
    stub_class_method(GetAaveV3MarketTool, :payload, stub) do
      get api_v1_tool_path(tool_name: "get_aave_v3_market", chain: "base", asset: "USDC")
      assert_response :success
      assert_equal "Aave V3", response.parsed_body["protocol"]
    end
    assert_equal({ chain: "base", asset: "USDC" }, seen)
  end
end
