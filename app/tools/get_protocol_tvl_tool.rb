# frozen_string_literal: true

class GetProtocolTvlTool < ApplicationTool
  tool_name "get_protocol_tvl"
  description "Get a DeFi protocol's TVL from DefiLlama: total TVL in USD, 1-day and 7-day change, category, borrowed amount for lending protocols, and per-chain TVL. Match by DefiLlama slug (e.g. 'aave-v3', 'uniswap-v3', 'lido') or exact name; if nothing matches, returns the closest protocols by name so you can retry."

  CHAIN_LIMIT = 15

  input_schema(
    properties: {
      protocol: { type: "string", description: "DefiLlama protocol slug or name, e.g. 'aave-v3' or 'Aave V3'." }
    },
    required: [ "protocol" ]
  )

  class << self
    def payload(protocol:)
      query = protocol.to_s.strip.downcase
      all = DefiLlamaDatasets.protocols
      match = all.find { |p| p[:slug] == query } || all.find { |p| p[:name].to_s.downcase == query }

      unless match
        suggestions = all.select { |p| p[:slug].to_s.include?(query) || p[:name].to_s.downcase.include?(query) }
                         .sort_by { |p| -p[:tvl_usd].to_f }.first(5)
                         .map { |p| { slug: p[:slug], name: p[:name], tvl_usd: p[:tvl_usd] } }
        return { error: "no DefiLlama protocol '#{protocol}'", suggestions: suggestions }
      end

      {
        source: "DefiLlama protocols",
        name: match[:name],
        slug: match[:slug],
        category: match[:category],
        tvl_usd: match[:tvl_usd],
        borrowed_usd: match[:borrowed_usd],
        change_1d_pct: match[:change_1d]&.round(3),
        change_7d_pct: match[:change_7d]&.round(3),
        url: match[:url],
        chain_count: match[:chains].size,
        top_chains: match[:chains].first(CHAIN_LIMIT).map { |c, tvl| { chain: c, tvl_usd: tvl } },
        fetched_at: DefiLlamaDatasets.fetched_at("protocols")&.utc&.iso8601
      }
    rescue DefiLlamaDatasets::Error => e
      { error: e.message }
    end
  end
end
