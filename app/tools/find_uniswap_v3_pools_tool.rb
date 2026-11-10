# frozen_string_literal: true

class FindUniswapV3PoolsTool < ApplicationTool
  tool_name "find_uniswap_v3_pools"
  description "Find every Uniswap V3 pool for a token pair on a chain, one per fee tier (0.01%, 0.05%, 0.3%, 1%), via the canonical Factory's getPool. Returns each pool's address, fee, active liquidity, tick and spot price (1 token_a in token_b). Tokens are 0x addresses or curated slugs (e.g. 'usdc-base'). Supported chains: eth, base, arbitrum, optimism, polygon, bnb."

  input_schema(
    properties: {
      chain:   { type: "string", description: "Chain slug: eth, base, arbitrum, optimism, polygon, bnb." },
      token_a: { type: "string", description: "First token: 0x address or curated slug." },
      token_b: { type: "string", description: "Second token: 0x address or curated slug." }
    },
    required: %w[chain token_a token_b]
  )

  class << self
    def payload(chain:, token_a:, token_b:)
      chain_record = Chain.find_by(slug: chain)
      return { error: "unknown chain: #{chain}" } unless chain_record
      return { error: "Uniswap V3 is not deployed on #{chain}; supported: #{ChainReader::UniswapV3Quoter::DEPLOYMENTS.keys.join(', ')}" } unless ChainReader::UniswapV3Quoter.supported?(chain_record)

      a, error = resolve_token(chain, token_a)
      return error if error
      b, error = resolve_token(chain, token_b)
      return error if error

      result = ChainReader::UniswapV3Quoter.pools(chain: chain_record, token_a: a, token_b: b)
      symbol_a = result.tokens[:a][:symbol]
      symbol_b = result.tokens[:b][:symbol]

      {
        protocol: "Uniswap V3",
        chain: chain,
        tokens: result.tokens,
        pool_count: result.pools.size,
        pools: result.pools.map do |p|
          p.except(:price_b_per_a).merge("price (1 #{symbol_a} in #{symbol_b})" => p[:price_b_per_a])
        end,
        liquidity_note: "liquidity is Uniswap V3 virtual liquidity at the current tick, not USD. Use quote_uniswap_v3_swap to see what a given size actually gets.",
        block_number: result.block_number,
        fetched_at: Time.current.utc.iso8601
      }
    rescue ChainReader::UniswapV3Quoter::Error => e
      { error: e.message }
    end
  end
end
