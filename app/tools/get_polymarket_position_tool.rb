# frozen_string_literal: true

class GetPolymarketPositionTool < ApplicationTool
  tool_name "get_polymarket_position"
  description "Get a wallet's Polymarket CTF outcome-token balances for up to 10 explicit markets. Input an address plus condition_ids and/or slugs."

  input_schema(
    properties: {
      address: { type: "string", description: "Wallet address to inspect." },
      condition_ids: {
        type: "array",
        items: { type: "string" },
        description: "Polymarket condition IDs. Maximum 10 combined with slugs."
      },
      slugs: {
        type: "array",
        items: { type: "string" },
        description: "Polymarket market slugs. Maximum 10 combined with condition_ids."
      }
    },
    required: [ "address" ]
  )

  class << self
    def payload(address:, condition_ids: nil, slugs: nil)
      {
        protocol: "Polymarket",
        address: address.to_s.downcase,
        positions: Polymarket::PositionFetcher.call(address: address, condition_ids: condition_ids, slugs: slugs)
      }
    rescue ArgumentError, PolymarketClient::Error => e
      { error: e.message }
    end
  end
end
