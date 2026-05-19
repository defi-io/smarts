# frozen_string_literal: true

class GetPolymarketMarketTool < ApplicationTool
  tool_name "get_polymarket_market"
  description "Get Polymarket market metadata and on-chain resolution state by slug or condition_id. Includes outcome token IDs, derived CTF position IDs, prices when present, payouts, and links."

  input_schema(
    properties: {
      slug: { type: "string", description: "Polymarket market slug from the URL. Preferred when available." },
      condition_id: { type: "string", description: "0x-prefixed Polymarket CTF condition ID. Alternative to slug." }
    }
  )

  class << self
    def payload(slug: nil, condition_id: nil)
      return { error: "provide slug or condition_id" } if slug.blank? && condition_id.blank?

      market = Polymarket::MarketFetcher.call(slug: slug, condition_id: condition_id)

      {
        protocol: market.protocol,
        slug: market.slug,
        condition_id: market.condition_id,
        question: market.question,
        outcomes: market.outcomes.map do |outcome|
          {
            name: outcome.name,
            token_id: outcome.token_id,
            position_id: outcome.position_id,
            price: outcome.price&.to_s("F")
          }
        end,
        neg_risk: market.neg_risk,
        state: market.state,
        payouts: market.payouts,
        payout_denominator: market.payout_denominator,
        end_date: market.end_date,
        volume_num: market.volume_num&.to_s("F"),
        active: market.active,
        closed: market.closed,
        accepting_orders: market.accepting_orders,
        enable_order_book: market.enable_order_book,
        collateral_token: market.collateral_token,
        block_number: market.block_number,
        fetched_at: market.fetched_at&.utc&.iso8601,
        links: links_for(market)
      }
    rescue ArgumentError, PolymarketClient::Error => e
      { error: e.message }
    end

    private

    def links_for(market)
      {
        polymarket_url: market.slug.present? ? "https://polymarket.com/market/#{market.slug}" : nil,
        exchange_contract: "https://smarts.md/polymarket-ctf-exchange-v2-polygon",
        conditional_tokens_contract: "https://smarts.md/polymarket-conditional-tokens-polygon"
      }
    end
  end
end
