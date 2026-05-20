# frozen_string_literal: true

class GetPolymarketResolutionTool < ApplicationTool
  tool_name "get_polymarket_resolution"
  description "Audit a Polymarket market resolution by slug or condition_id. Reads CTF payout state on-chain, includes Gamma market status and outcome token IDs, and flags whether API-level closed status agrees with the chain."

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
        resolution: resolution_payload(market),
        gamma_market: gamma_payload(market),
        outcomes: outcome_payloads(market),
        audit: audit_payload(market),
        sources: sources_payload,
        block_number: market.block_number,
        fetched_at: market.fetched_at&.utc&.iso8601,
        links: links_for(market)
      }
    rescue ArgumentError, PolymarketClient::Error => e
      { error: e.message }
    end

    private

    def resolution_payload(market)
      {
        state: market.state,
        payouts: market.payouts,
        payout_denominator: market.payout_denominator,
        resolved: market.state.to_s == "resolved"
      }
    end

    def gamma_payload(market)
      {
        active: market.active,
        closed: market.closed,
        accepting_orders: market.accepting_orders,
        enable_order_book: market.enable_order_book,
        neg_risk: market.neg_risk,
        end_date: market.end_date
      }
    end

    def outcome_payloads(market)
      market.outcomes.each_with_index.map do |outcome, index|
        payout = Array(market.payouts)[index]
        {
          name: outcome.name,
          token_id: outcome.token_id,
          position_id: outcome.position_id,
          payout: payout,
          winning: payout.present? && market.payout_denominator.to_i.positive? ? payout.to_i.positive? : nil
        }
      end
    end

    def audit_payload(market)
      resolved_on_chain = market.state.to_s == "resolved"
      api_closed = market.closed == true

      status =
        if resolved_on_chain && api_closed
          "consistent"
        elsif resolved_on_chain && !api_closed
          "chain_resolved_api_open"
        elsif !resolved_on_chain && api_closed
          "api_closed_chain_unresolved"
        else
          "unresolved"
        end

      {
        status: status,
        chain_resolved: resolved_on_chain,
        gamma_closed: api_closed,
        notes: audit_notes(status)
      }
    end

    def audit_notes(status)
      case status
      when "consistent"
        "CTF payoutDenominator is non-zero and Gamma marks the market closed."
      when "chain_resolved_api_open"
        "The chain has a final payout vector, but Gamma does not mark the market closed."
      when "api_closed_chain_unresolved"
        "Gamma marks the market closed, but CTF payoutDenominator is still zero."
      else
        "No final payout vector is available on-chain yet."
      end
    end

    def sources_payload
      {
        chain: {
          contract: "Polymarket Conditional Tokens",
          slug: "polymarket-conditional-tokens-polygon",
          fields: {
            state: "Derived from payoutDenominator(conditionId).",
            payouts: "Read from payoutNumerators(conditionId, outcomeIndex).",
            block_number: "Block returned by the on-chain read."
          }
        },
        api: {
          provider: "Polymarket Gamma API",
          fields: {
            gamma_market: "Market active/closed/order-book metadata.",
            outcomes: "Outcome labels and CLOB token IDs."
          }
        }
      }
    end

    def links_for(market)
      {
        polymarket_url: market.slug.present? ? "https://polymarket.com/market/#{market.slug}" : nil,
        conditional_tokens_contract: "/polymarket-conditional-tokens-polygon",
        uma_adapter_contract: "/polymarket-uma-adapter-v3-polygon"
      }
    end
  end
end
