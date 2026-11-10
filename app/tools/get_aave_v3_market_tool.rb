# frozen_string_literal: true

class GetAaveV3MarketTool < ApplicationTool
  tool_name "get_aave_v3_market"
  description "Get live state of the Aave V3 core lending market on a chain: per-asset supply/borrow APY, total supplied and borrowed (token units and USD via DefiLlama), utilization, LTV, liquidation threshold/bonus, reserve factor, caps, and frozen/paused flags. Read directly from the Aave V3 Pool contract. Pass `asset` (symbol or token address) to get a single reserve. Supported chains: eth, base, arbitrum, optimism, polygon, bnb."

  input_schema(
    properties: {
      chain: { type: "string", description: "Chain slug: eth, base, arbitrum, optimism, polygon, bnb. Required unless `slug` is given." },
      slug:  { type: "string", description: "Curated slug of an Aave V3 Pool, e.g. 'aavev3-pool-base'. Alternative to `chain`." },
      asset: { type: "string", description: "Optional. Reserve symbol (e.g. 'USDC', case-insensitive) or underlying token address. Omit to list every reserve." }
    }
  )

  class << self
    def payload(chain: nil, slug: nil, asset: nil)
      chain_slug, error = resolve_chain_slug(chain: chain, slug: slug)
      return error if error

      chain_record = Chain.find_by(slug: chain_slug)
      return { error: "unknown chain: #{chain_slug}" } unless chain_record

      tier_error = check_full_tier(chain_record)
      return tier_error if tier_error

      pool = ProtocolAdapters::AaveV3PoolAdapter.pool_address_for(chain_slug)
      return { error: "no Aave V3 market on #{chain_slug}; supported: #{supported_chains.join(', ')}" } unless pool

      adapter = ProtocolAdapters::AaveV3PoolAdapter.new(Contract.new(chain: chain_record, address: pool))
      data = adapter.panel_data
      return { error: data[:error] } if data[:error]

      reserves = data[:reserves]
      if asset.present?
        reserves = reserves.select { |r| asset_match?(r, asset) }
        return { error: "no reserve matching '#{asset}' in Aave V3 on #{chain_slug}" } if reserves.empty?
      end

      {
        protocol: "Aave V3",
        chain: chain_slug,
        pool: pool,
        total_supplied_usd: data[:total_supplied_usd],
        total_borrowed_usd: data[:total_borrowed_usd],
        reserve_count: data[:reserve_count],
        reserves: reserves,
        rates_note: "APYs are the current variable rates (per-second compounding of the Pool's ray APR). LTV 0 means the asset cannot back new borrows outside eMode.",
        block_number: data[:block_number],
        fetched_at: data[:fetched_at]&.utc&.iso8601,
        price_observed_at: data[:price_observed_at]&.utc&.iso8601
      }
    end

    private

    def resolve_chain_slug(chain:, slug:)
      if slug.present?
        lookup = ContractSlugResolver.resolve(slug)
        return [ nil, { error: "unknown slug: #{slug}" } ] unless lookup

        chain_slug, address = lookup
        unless ProtocolAdapters::AaveV3PoolAdapter.pool_address_for(chain_slug) == address.downcase
          return [ nil, { error: "#{slug} is not an Aave V3 Pool" } ]
        end

        [ chain_slug, nil ]
      elsif chain.present?
        [ chain, nil ]
      else
        [ nil, { error: "either `chain` or `slug` required" } ]
      end
    end

    def asset_match?(reserve, query)
      q = query.to_s.downcase
      reserve[:address] == q || reserve[:symbol].to_s.downcase == q
    end

    def supported_chains
      ProtocolAdapters::AaveV3PoolAdapter::POOL_BY_CHAIN.keys
    end
  end
end
