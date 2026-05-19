# frozen_string_literal: true

require "set"

module ProtocolAdapters
  class PolymarketAdapter < Base
    ROLES_BY_ADDRESS = {
      "0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e" => :exchange,
      "0xe111180000d2663c0091e4f400237545b87b996b" => :exchange,
      "0xc5d563a36ae78145c45a50134d48a1215220f80a" => :exchange,
      "0xe2222d279d744050d28e00520010520000310f59" => :exchange,
      "0xd91e80cf2e7be2e162c6513ced06f1dd0da35296" => :neg_risk_adapter,
      "0x4d97dcd97ec945f40cf65f87097ace5ea0476045" => :ctf,
      "0x71392e133063cc0d16f40e1f9b60227404bc03f7" => :uma_adapter,
      "0x6a9d222616c90fca5754cd1333cfd9b7fb6a4f74" => :uma_adapter,
      "0x2f5e3684cb1f318ec51b00edba38d79ac2c0aa9d" => :uma_adapter
    }.freeze

    ADDRESSES = ROLES_BY_ADDRESS.keys.to_set.freeze

    def self.type_tag
      "polymarket"
    end

    def self.matches?(contract)
      contract.chain.slug == "polygon" && ADDRESSES.include?(contract.address.to_s.downcase)
    end

    def protocol_name
      "Polymarket"
    end

    def role
      ROLES_BY_ADDRESS.fetch(contract.address.downcase)
    end

    def display_name
      case role
      when :exchange
        "Polymarket Exchange"
      when :ctf
        "Polymarket Conditional Tokens"
      when :uma_adapter
        "Polymarket UMA Adapter"
      when :neg_risk_adapter
        "Polymarket Neg-Risk Adapter"
      end
    end

    def template_partial
      "protocol_adapters/polymarket_#{role}"
    end

    def panel_data
      Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        {
          role: role,
          role_label: role_label,
          source_label: "Mainstream active markets: macro, crypto, finance, geopolitics",
          top_markets: PolymarketClient.fetch_top_markets(limit: 5),
          fetched_at: Time.current
        }
      rescue PolymarketClient::Error => e
        { role: role, role_label: role_label, error: e.message }
      end
    end

    private

    def cache_key
      "protocol_panel:polymarket:v3:#{chain.slug}:#{contract.address}"
    end

    def role_label
      case role
      when :exchange
        "Order matching"
      when :ctf
        "Outcome token ledger"
      when :uma_adapter
        "Binary-market oracle adapter"
      when :neg_risk_adapter
        "Multi-outcome oracle adapter"
      end
    end
  end
end
