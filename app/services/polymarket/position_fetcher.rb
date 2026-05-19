# frozen_string_literal: true

module Polymarket
  class PositionFetcher
    MAX_MARKETS = 10

    class << self
      def call(address:, condition_ids: nil, slugs: nil)
        owner = normalize_address(address)
        ids = resolve_condition_ids(condition_ids: condition_ids, slugs: slugs)
        raise ArgumentError, "at least one condition_id or slug required" if ids.empty?
        raise ArgumentError, "maximum #{MAX_MARKETS} markets per request" if ids.size > MAX_MARKETS

        polygon = Chain.find_by!(slug: "polygon")
        ids.map { |condition_id| build_market_position(chain: polygon, owner: owner, condition_id: condition_id) }
      end

      private

      def resolve_condition_ids(condition_ids:, slugs:)
        explicit = Array(condition_ids).filter_map { |id| normalize_condition_id(id) }
        from_slugs = Array(slugs).filter_map do |slug|
          next if slug.blank?

          PolymarketClient.fetch_market_by_slug(slug).condition_id
        end
        (explicit + from_slugs).uniq
      end

      def build_market_position(chain:, owner:, condition_id:)
        market = PolymarketClient.fetch_market_by_condition_id(condition_id)
        resolution = ResolutionReader.call(chain: chain, condition_id: market.condition_id)
        index_sets = (0...market.outcomes.size).map { |index| 1 << index }
        position_ids = ChainReader::ConditionalTokensReader.position_ids(
          chain: chain,
          ct_address: ResolutionReader::CONDITIONAL_TOKENS,
          collateral: market.collateral_token || PolymarketClient::PUSD,
          condition_id: market.condition_id,
          index_sets: index_sets
        )
        balances = ChainReader::ConditionalTokensReader.balances(
          chain: chain,
          ct_address: ResolutionReader::CONDITIONAL_TOKENS,
          owner: owner,
          position_ids: position_ids
        )

        {
          condition_id: market.condition_id,
          slug: market.slug,
          question: market.question,
          state: resolution.state,
          payout_denominator: resolution.payout_denominator,
          block_number: [ resolution.block_number, balances.block_number ].compact.min,
          outcomes: market.outcomes.each_with_index.map do |name, index|
            balance = balances.values[index]
            payout = resolution.payouts&.[](index).to_i
            {
              name: name,
              token_id: market.tokens[index]&.token_id || market.clob_token_ids[index],
              position_id: position_ids[index],
              balance: balance,
              redeemable: resolution.state == :resolved && payout.positive? && balance.to_i.positive?
            }
          end
        }
      end

      def normalize_address(value)
        address = value.to_s.downcase
        raise ArgumentError, "invalid address" unless address.match?(/\A0x[0-9a-f]{40}\z/)

        address
      end

      def normalize_condition_id(value)
        return nil if value.blank?

        hex = value.to_s.downcase
        hex = "0x#{hex}" unless hex.start_with?("0x")
        raise ArgumentError, "invalid condition_id" unless hex.match?(/\A0x[0-9a-f]{64}\z/)

        hex
      end
    end
  end
end
