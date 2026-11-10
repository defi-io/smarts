# frozen_string_literal: true

class GetStablecoinSupplyTool < ApplicationTool
  tool_name "get_stablecoin_supply"
  description "Get a stablecoin's circulating supply from DefiLlama: total circulating, 1-day and 7-day change, peg type and mechanism, current price, and the per-chain breakdown. Pass `chain` to also get that chain's figure. Amounts are in peg units (USD for peggedUSD, EUR for peggedEUR). Matches by symbol (e.g. USDC, USDT, EURC); when several stablecoins share a symbol the largest is returned first."

  CHAIN_LIMIT = 15

  input_schema(
    properties: {
      symbol: { type: "string", description: "Stablecoin symbol, case-insensitive, e.g. 'USDC'." },
      chain:  { type: "string", description: "Optional chain slug (eth, base, arbitrum, optimism, bnb, polygon, robinhood, arc) for that chain's circulating supply." }
    },
    required: [ "symbol" ]
  )

  class << self
    def payload(symbol:, chain: nil)
      if chain.present? && !DefiLlamaDatasets::CHAIN_NAMES.key?(chain)
        return { error: "unsupported chain: #{chain}; use one of #{DefiLlamaDatasets::CHAIN_NAMES.keys.join(', ')}" }
      end

      matches = DefiLlamaDatasets.stablecoins
                                 .select { |s| s[:symbol].to_s.casecmp?(symbol.to_s) }
                                 .sort_by { |s| -s[:circulating].to_f }
      return { error: "no stablecoin with symbol '#{symbol}' on DefiLlama" } if matches.empty?

      main = matches.first
      result = {
        source: "DefiLlama stablecoins",
        name: main[:name],
        symbol: main[:symbol],
        peg_type: main[:peg_type],
        peg_mechanism: main[:peg_mechanism],
        price: main[:price],
        circulating: main[:circulating],
        change_1d_pct: pct_change(main[:circulating], main[:circulating_prev_day]),
        change_7d_pct: pct_change(main[:circulating], main[:circulating_prev_week]),
        chain_count: main[:chains].size,
        top_chains: main[:chains].first(CHAIN_LIMIT).map { |c, amount| { chain: c, circulating: amount } },
        fetched_at: DefiLlamaDatasets.fetched_at("stablecoins")&.utc&.iso8601
      }

      if chain.present?
        amount = main[:chains].to_h[chain]
        result[:chain] = { chain: chain, circulating: amount, share_pct: share(amount, main[:circulating]) }
      end

      if matches.size > 1
        result[:other_matches] = matches.drop(1).first(5).map { |s| { name: s[:name], circulating: s[:circulating] } }
      end

      result
    rescue DefiLlamaDatasets::Error => e
      { error: e.message }
    end

    private

    def pct_change(now, before)
      return nil if now.nil? || before.to_f.zero?

      ((now - before) / before * 100).round(3)
    end

    def share(part, whole)
      return nil if part.nil? || whole.to_f.zero?

      (part / whole * 100).round(3)
    end
  end
end
