# frozen_string_literal: true

# Thin REST wrapper around MCP tool payloads for ChatGPT Custom GPTs and
# other OpenAPI consumers. Each tool is exposed as:
#
#   GET /api/v1/:tool_name?slug=usdc-eth&chain=eth&...
#
# The controller introspects the tool's `input_schema` to permit only
# declared parameters, coerces types (integer, array), and delegates to
# the tool's `payload` class method — the same code path MCP uses.
module Api
  module V1
    class ToolsController < ApplicationController
      allow_unauthenticated_access
      skip_forgery_protection

      # Public tools only — auth-gated publishing tools are excluded.
      TOOL_MAP = {
        "get_contract_info"        => GetContractInfoTool,
        "get_contract_source"      => GetContractSourceTool,
        "get_admin_risk"           => GetAdminRiskTool,
        "get_erc20_info"           => GetErc20InfoTool,
        "get_polymarket_market"    => GetPolymarketMarketTool,
        "get_polymarket_position"  => GetPolymarketPositionTool,
        "get_polymarket_resolution" => GetPolymarketResolutionTool,
        "get_recent_events"        => GetRecentEventsTool,
        "get_uniswap_v3_pool"      => GetUniswapV3PoolTool,
        "inspect_address"          => InspectAddressTool,
        "read_contract_state"      => ReadContractStateTool
      }.freeze

      def show
        tool_class = TOOL_MAP[params[:tool_name]]
        return render json: { error: "unknown tool: #{params[:tool_name]}" }, status: :not_found unless tool_class

        kwargs = extract_kwargs(tool_class)
        result = tool_class.payload(**kwargs)

        expires_in 60.seconds, public: true
        render json: result
      rescue ArgumentError => e
        render json: { error: e.message }, status: :bad_request
      rescue StandardError => e
        Rails.logger.warn("[Api::V1::ToolsController] #{params[:tool_name]} error: #{e.class}: #{e.message}")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # Introspect the tool's input_schema to build keyword args from query
      # params, coercing types where needed.
      def extract_kwargs(tool_class)
        schema = tool_class.input_schema_value.to_h
        properties = schema[:properties] || {}

        kwargs = {}
        properties.each do |name, prop|
          name_s = name.to_s
          next unless params.key?(name_s)

          value = params[name_s]
          type = prop[:type].to_s

          kwargs[name.to_sym] = coerce(value, type)
        end
        kwargs
      end

      def coerce(value, type)
        case type
        when "integer"
          value.to_i
        when "array"
          value.is_a?(Array) ? value : value.to_s.split(",")
        else
          value
        end
      end
    end
  end
end
