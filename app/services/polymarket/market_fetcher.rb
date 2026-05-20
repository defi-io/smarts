# frozen_string_literal: true

module Polymarket
  class MarketFetcher
    CACHE_TTL = 30.seconds

    Outcome = Struct.new(:name, :token_id, :position_id, :price, :mid_price, :best_bid, :best_ask, keyword_init: true)

    Result = Struct.new(
      :protocol, :slug, :condition_id, :question, :outcomes, :neg_risk,
      :state, :payouts, :payout_denominator, :end_date, :volume_num,
      :active, :closed, :accepting_orders, :enable_order_book,
      :collateral_token, :block_number, :fetched_at,
      keyword_init: true
    )

    class << self
      def call(slug: nil, condition_id: nil)
        raise ArgumentError, "slug or condition_id required" if slug.blank? && condition_id.blank?

        cache_id = slug.present? ? "slug:#{slug}" : "condition:#{condition_id.to_s.downcase}"
        Rails.cache.fetch("polymarket:market_fetcher:v3:#{cache_id}", expires_in: CACHE_TTL) do
          market = slug.present? ? PolymarketClient.fetch_market_by_slug(slug) : PolymarketClient.fetch_market_by_condition_id(condition_id)
          polygon = Chain.find_by!(slug: "polygon")
          resolution = ResolutionReader.call(chain: polygon, condition_id: market.condition_id)
          position_ids = derive_position_ids(polygon, market)
          live_prices = fetch_live_prices(market)

          Result.new(
            protocol: "Polymarket",
            slug: market.slug,
            condition_id: market.condition_id,
            question: market.question,
            outcomes: build_outcomes(market, position_ids, live_prices),
            neg_risk: market.neg_risk,
            state: resolution.state,
            payouts: resolution.payouts,
            payout_denominator: resolution.payout_denominator,
            end_date: market.end_date,
            volume_num: market.volume_num,
            active: market.active,
            closed: market.closed,
            accepting_orders: market.accepting_orders,
            enable_order_book: market.enable_order_book,
            collateral_token: market.collateral_token,
            block_number: resolution.block_number,
            fetched_at: Time.current
          )
        end
      end

      private

      def derive_position_ids(chain, market)
        count = market.outcomes.size
        return [] if count.zero?

        ChainReader::ConditionalTokensReader.position_ids(
          chain: chain,
          ct_address: ResolutionReader::CONDITIONAL_TOKENS,
          collateral: market.collateral_token || PolymarketClient::PUSD,
          condition_id: market.condition_id,
          index_sets: index_sets(count)
        )
      rescue StandardError => e
        Rails.logger.warn("[Polymarket::MarketFetcher] position id derivation failed: #{e.class}: #{e.message}")
        []
      end

      def fetch_live_prices(market)
        return {} unless market.active && !market.closed && market.enable_order_book

        token_ids = market.tokens.map(&:token_id).compact
        PolymarketClient.fetch_live_prices(token_ids)
      rescue PolymarketClient::Error => e
        Rails.logger.warn("[Polymarket::MarketFetcher] live price fetch failed: #{e.message}")
        {}
      end

      def build_outcomes(market, position_ids, live_prices)
        market.outcomes.each_with_index.map do |name, index|
          token = market.tokens[index]
          live = live_prices[token&.token_id] || {}
          Outcome.new(
            name: name,
            token_id: token&.token_id || market.clob_token_ids[index],
            position_id: position_ids[index],
            price: token&.price,
            mid_price: live[:mid_price] || token&.mid_price,
            best_bid: live[:best_bid] || token&.best_bid,
            best_ask: live[:best_ask] || token&.best_ask
          )
        end
      end

      def index_sets(count)
        (0...count).map { |index| 1 << index }
      end
    end
  end
end
