# frozen_string_literal: true

class GetYieldPoolsTool < ApplicationTool
  tool_name "get_yield_pools"
  description "Find yield pools from DefiLlama on the chains Smarts supports (eth, base, arbitrum, optimism, bnb, polygon, robinhood, arc). Filter by project (DefiLlama slug, e.g. 'aave-v3', 'morpho-blue'), chain, token symbol (substring, e.g. 'USDC' also matches 'USDC-WETH'), minimum TVL and stablecoin-only. Returns pools sorted by TVL (or by APY with sort='apy'), with total/base/reward APY, 30-day mean APY, 7-day APY change, IL risk and exposure."

  DEFAULT_LIMIT = 20
  MAX_LIMIT = 50
  DEFAULT_MIN_TVL = 1_000_000

  input_schema(
    properties: {
      project:         { type: "string", description: "DefiLlama project slug, e.g. 'aave-v3'." },
      chain:           { type: "string", description: "Chain slug: eth, base, arbitrum, optimism, bnb, polygon, robinhood, arc." },
      symbol:          { type: "string", description: "Token symbol substring, case-insensitive." },
      min_tvl_usd:     { type: "number", description: "Minimum pool TVL in USD. Default 1,000,000 — tiny pools often show meaningless APYs." },
      stablecoin_only: { type: "boolean", description: "Only pools DefiLlama flags as stablecoin pools." },
      sort:            { type: "string", enum: %w[tvl apy], description: "Sort by 'tvl' (default) or 'apy'." },
      limit:           { type: "integer", description: "Max pools to return (default 20, max 50)." }
    }
  )

  class << self
    def payload(project: nil, chain: nil, symbol: nil, min_tvl_usd: DEFAULT_MIN_TVL, stablecoin_only: false, sort: "tvl", limit: DEFAULT_LIMIT)
      if chain.present? && !DefiLlamaDatasets::CHAIN_NAMES.key?(chain)
        return { error: "unsupported chain: #{chain}; use one of #{DefiLlamaDatasets::CHAIN_NAMES.keys.join(', ')}" }
      end

      sym = symbol.to_s.downcase.presence
      pools = DefiLlamaDatasets.yield_pools.select do |p|
        (project.blank? || p[:project] == project.to_s.downcase) &&
          (chain.blank? || p[:chain] == chain) &&
          (sym.nil? || p[:symbol].to_s.downcase.include?(sym)) &&
          p[:tvl_usd].to_f >= min_tvl_usd.to_f &&
          (!stablecoin_only || p[:stablecoin])
      end

      sort_key = sort.to_s == "apy" ? :apy : :tvl_usd
      pools = pools.sort_by { |p| -p[sort_key].to_f }
      capped = limit.to_i.clamp(1, MAX_LIMIT)

      {
        source: "DefiLlama yields",
        filters: { project: project, chain: chain, symbol: symbol, min_tvl_usd: min_tvl_usd, stablecoin_only: stablecoin_only, sort: sort_key == :apy ? "apy" : "tvl" }.compact,
        match_count: pools.size,
        pools: pools.first(capped),
        apy_note: "APY values are percentages (4.7 = 4.7%). apy = apy_base + apy_reward; reward APY depends on incentive token prices and can stop at any time."
      }
    rescue DefiLlamaDatasets::Error => e
      { error: e.message }
    end
  end
end
