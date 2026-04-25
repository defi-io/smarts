# frozen_string_literal: true

class GetErc20InfoTool < ApplicationTool
  tool_name "get_erc20_info"
  description "Get live state of an ERC-20 token: supply (raw + human-formatted), price, market cap, issuer, plus centralized-stablecoin admin controls (paused status, owner / masterMinter / pauser / blacklister / rescuer) when the contract exposes them. Accepts slug or chain+address."

  arguments do
    optional(:slug).filled(:string)
      .description("Curated slug like 'usdc-eth' or 'usdc-base'. Alternative to chain+address.")
    optional(:chain).filled(:string)
      .description("Chain slug: eth, base, arbitrum, optimism, or polygon. Required unless `slug` is given.")
    optional(:address).filled(:string)
      .description("Token address (0x-prefixed). Required unless `slug` is given.")
  end

  def call(chain: nil, address: nil, slug: nil)
    resolved = resolve_contract(chain: chain, address: address, slug: slug)
    return resolved if resolved.is_a?(Hash)

    _chain_record, contract = resolved
    adapter = ProtocolAdapters::Base.resolve(contract)
    unless adapter.is_a?(ProtocolAdapters::GenericErc20Adapter)
      return { error: "not an ERC-20 token contract" }
    end

    data = adapter.panel_data
    return { error: data[:error] } if data[:error]

    {
      symbol: data[:symbol],
      name: data[:name],
      decimals: data[:decimals],
      chain: contract.chain.slug,
      address: contract.address,
      total_supply: {
        raw: data[:total_supply_raw],
        formatted: data[:total_supply_formatted]
      },
      price_usd: data[:price_usd],
      market_cap_usd: data[:market_cap_usd],
      issuer: data[:issuer],
      admin_status: data[:admin_status],
      admin_roles: data[:admin_roles],
      block_number: data[:block_number],
      fetched_at: data[:fetched_at]&.iso8601
    }
  end
end
