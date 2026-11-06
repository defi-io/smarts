# frozen_string_literal: true

module Seo
  class Copy
    class << self
      def homepage(featured_items: [])
        labels = Array(featured_items).filter_map do |item|
          item[:symbol].presence || item[:name].presence
        end.first(4)

        list = labels.present? ? labels.to_sentence : "blue-chip contracts"

        "Live docs for every smart contract. Start with #{list} across Ethereum, Base, Arbitrum, Optimism, BNB Smart Chain, Polygon, Robinhood Chain, and Arc, or connect your AI agent to query verified on-chain state."
      end

      def contract(contract_name:, chain_name:, classification: nil, address: nil)
        suffix = address.present? ? " at #{address}" : ""
        if classification&.display_name.present?
          "Live on-chain docs for #{contract_name} (#{classification.display_name}) on #{chain_name}#{suffix}. Supply, admin controls, live state, and source - read straight from the chain."
        else
          "Live on-chain docs for #{contract_name}#{suffix} on #{chain_name}. View functions, admin controls, source code - current from the chain."
        end
      end
    end
  end
end
