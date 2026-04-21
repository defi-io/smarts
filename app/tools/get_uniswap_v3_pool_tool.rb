# frozen_string_literal: true

class GetUniswapV3PoolTool < ApplicationTool
  tool_name "get_uniswap_v3_pool"
  description "Get live state of a Uniswap V3 pool: token pair, fee tier, current price (both directions), active liquidity, current tick, and TVL in USD (via DefiLlama token prices)."

  arguments do
    required(:chain).filled(:string)
      .description("Chain slug: eth, base, arbitrum, optimism, or polygon.")
    required(:address).filled(:string)
      .description("Pool address (0x-prefixed).")
  end

  def call(chain:, address:)
    chain_record = Chain.find_by(slug: chain)
    return { error: "unknown chain: #{chain}" } unless chain_record

    contract = Contract.find_by(chain: chain_record, address: address.downcase)
    return { error: "pool not indexed — visit https://smarts.md/#{chain}/#{address} first" } unless contract

    adapter = ProtocolAdapters::Base.resolve(contract)
    unless adapter.is_a?(ProtocolAdapters::UniswapV3Adapter)
      return { error: "not a Uniswap V3 pool" }
    end

    data = adapter.panel_data
    return { error: data[:error] } if data[:error]

    {
      protocol: "Uniswap V3",
      pair: "#{data[:token0][:symbol]}/#{data[:token1][:symbol]}",
      fee: data[:fee_pct],
      price: {
        "1 #{data[:token1][:symbol]} in #{data[:token0][:symbol]}" => data[:price_0_per_1],
        "1 #{data[:token0][:symbol]} in #{data[:token1][:symbol]}" => data[:price_1_per_0]
      },
      tick: data[:tick],
      liquidity: data[:liquidity],
      tvl_usd: data[:tvl_usd],
      tokens: {
        token0: data[:token0].slice(:symbol, :decimals, :address),
        token1: data[:token1].slice(:symbol, :decimals, :address)
      }
    }
  end
end
