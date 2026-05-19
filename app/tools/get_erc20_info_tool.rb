# frozen_string_literal: true

class GetErc20InfoTool < ApplicationTool
  tool_name "get_erc20_info"
  description "Get live state of an ERC-20 token: supply (raw + human-formatted), price, market cap, and issuer. For admin / privilege controls (paused, owner, mintable, upgradeable, etc.) and recent governance activity, the contract page itself exposes an Admin & Risk section — those are not returned here. Accepts slug or chain+address."

  input_schema(
    properties: {
      slug:    { type: "string", description: "Curated slug like 'usdc-eth' or 'usdc-base'. Alternative to chain+address." },
      chain:   { type: "string", description: "Chain slug: eth, base, arbitrum, optimism, or polygon. Required unless `slug` is given." },
      address: { type: "string", description: "Token address (0x-prefixed). Required unless `slug` is given." }
    }
  )

  class << self
    def payload(chain: nil, address: nil, slug: nil)
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
        price_observed_at: data[:price_observed_at]&.utc&.iso8601,
        market_cap_usd: data[:market_cap_usd],
        issuer: data[:issuer],
        block_number: data[:block_number],
        fetched_at: data[:fetched_at]&.utc&.iso8601
      }
    end
  end
end
