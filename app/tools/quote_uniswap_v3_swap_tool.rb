# frozen_string_literal: true

class QuoteUniswapV3SwapTool < ApplicationTool
  tool_name "quote_uniswap_v3_swap"
  description "Quote an exact-input swap on Uniswap V3 via the canonical QuoterV2: how much token_out you get for amount_in of token_in in each fee-tier pool (or one tier with `fee`), the execution price, spot price, price impact (total, and excluding the LP fee), ticks crossed and gas estimate. The best single-pool quote is returned as `best`. Single-hop, single-pool only — real routers may split or route through other pools for a better price. Tokens are 0x addresses or curated slugs. Supported chains: eth, base, arbitrum, optimism, polygon, bnb."

  input_schema(
    properties: {
      chain:     { type: "string", description: "Chain slug: eth, base, arbitrum, optimism, polygon, bnb." },
      token_in:  { type: "string", description: "Token sold: 0x address or curated slug." },
      token_out: { type: "string", description: "Token bought: 0x address or curated slug." },
      amount_in: { type: "string", description: "Amount of token_in in human units, e.g. '1.5' (not wei)." },
      fee:       { type: "integer", description: "Optional fee tier in hundredths of a bip: 100, 500, 3000 or 10000. Omit to compare all tiers." }
    },
    required: %w[chain token_in token_out amount_in]
  )

  class << self
    def payload(chain:, token_in:, token_out:, amount_in:, fee: nil)
      chain_record = Chain.find_by(slug: chain)
      return { error: "unknown chain: #{chain}" } unless chain_record
      return { error: "Uniswap V3 is not deployed on #{chain}; supported: #{ChainReader::UniswapV3Quoter::DEPLOYMENTS.keys.join(', ')}" } unless ChainReader::UniswapV3Quoter.supported?(chain_record)

      t_in, error = resolve_token(chain, token_in)
      return error if error
      t_out, error = resolve_token(chain, token_out)
      return error if error

      result = ChainReader::UniswapV3Quoter.quote(chain: chain_record, token_in: t_in, token_out: t_out, amount_in: amount_in, fee: fee)
      return { error: "every pool reverted the quote — the size is likely larger than available liquidity", quotes: result.quotes } unless result.best

      {
        protocol: "Uniswap V3",
        chain: chain,
        token_in: result.token_in,
        token_out: result.token_out,
        amount_in: result.amount_in,
        best: strip_raw(result.best),
        quotes: result.quotes.map { |q| strip_raw(q) },
        price_note: "Prices are token_out per 1 token_in. price_impact_pct is the shortfall vs spot including the LP fee; price_impact_ex_fee_pct removes the fee.",
        block_number: result.block_number
      }
    rescue ChainReader::UniswapV3Quoter::Error => e
      { error: e.message }
    end

    private

    def strip_raw(quote)
      quote.except(:amount_out_raw)
    end
  end
end
