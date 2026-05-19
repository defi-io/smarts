# frozen_string_literal: true

require "bigdecimal"

class PolymarketClient
  BASE_GAMMA = "https://gamma-api.polymarket.com"
  BASE_CLOB = "https://clob.polymarket.com"
  TIMEOUT = 10
  CACHE_TTL = 5.minutes

  class Error < StandardError; end
  class NotFound < Error; end

  Token = Struct.new(:outcome, :token_id, :price, :winner, keyword_init: true)

  Market = Struct.new(
    :condition_id, :question_id, :slug, :question, :outcomes, :clob_token_ids,
    :tokens, :end_date, :active, :closed, :neg_risk, :volume_num,
    :accepting_orders, :enable_order_book, :collateral_token, :tags, :event_title,
    keyword_init: true
  )

  PUSD = "0xc011a7e12a19f7b1f670d46f03b03f3342e82dfb"
  USDC_E = "0x2791bca1f2de4661ed88a30c99a7a9449aa84174"

  MAINSTREAM_TAG_SLUGS = %w[
    crypto bitcoin ethereum finance economy business stocks fed inflation recession
    world international geopolitics ukraine russia china taiwan israel macro
  ].freeze

  ENTERTAINMENT_TAG_SLUGS = %w[
    pop-culture pop culture entertainment celebrity celebrities music movies tv sports
    soccer basketball football baseball tennis ufc esports gaming
  ].freeze

  MAINSTREAM_KEYWORDS = %w[
    bitcoin btc ethereum eth crypto fed rates inflation recession cpi gdp unemployment
    election president senate congress trump biden china taiwan russia ukraine israel
    oil gold dollar stock stocks microstrategy tesla nvidia
  ].freeze

  NOISY_KEYWORDS = %w[
    gta album rihanna playboi carti jesus celebrity celebrities movie oscars grammy
    nba nfl mlb nhl ufc soccer football tennis lebron kanye swift taylor drake
    beyonce mrbeast messi ronaldo kardashian
  ].freeze

  class << self
    def fetch_market_by_slug(slug)
      normalized = slug.to_s.strip
      raise ArgumentError, "slug required" if normalized.blank?

      Rails.cache.fetch("polymarket:market:slug:v3:#{normalized}", expires_in: CACHE_TTL) do
        payload = get_gamma("/markets/slug/#{normalized}")
        raise NotFound, "Polymarket market not found: #{normalized}" if payload.blank?

        parse_market(payload)
      end
    end

    def fetch_market_by_condition_id(condition_id)
      cid = normalize_condition_id(condition_id)

      Rails.cache.fetch("polymarket:market:condition:v3:#{cid}", expires_in: CACHE_TTL) do
        gamma_market = fetch_gamma_market_by_condition_id(cid)
        clob_market = fetch_clob_market_by_condition_id(cid)

        raise NotFound, "Polymarket market not found: #{cid}" if gamma_market.blank? && clob_market.blank?

        parse_market(gamma_market || {}, clob_market: clob_market || {}, condition_id: cid)
      end
    end

    def fetch_top_markets(limit: 5)
      safe_limit = limit.to_i.clamp(1, 20)

      Rails.cache.fetch("polymarket:mainstream_markets:v3:#{safe_limit}", expires_in: 5.minutes) do
        events = get_gamma("/events", active: true, closed: false, order: "volume_24hr", ascending: false, limit: 100)
        candidates = Array(events).flat_map { |event| markets_from_event(event) }

        mainstream = candidates
          .reject { |market| noisy_market?(market) }
          .select { |market| mainstream_market?(market) }
          .sort_by { |market| -(market.volume_num || BigDecimal("0")) }

        (mainstream.presence || candidates.reject { |market| noisy_market?(market) }).first(safe_limit)
      end
    end

    private

    def markets_from_event(event)
      tags = Array(value_at(event, "tags")).map { |tag| value_at(tag, "slug", "label").to_s.downcase }.reject(&:blank?)
      event_title = value_at(event, "title")

      Array(value_at(event, "markets")).filter_map do |entry|
        market = parse_market(entry, event_tags: tags, event_title: event_title)
        next unless market.active && !market.closed

        market
      end
    end

    def fetch_gamma_market_by_condition_id(condition_id)
      payload = get_gamma("/markets", condition_ids: condition_id, limit: 1)
      Array(payload).first
    rescue NotFound
      nil
    end

    def fetch_clob_market_by_condition_id(condition_id)
      get_clob("/clob-markets/#{condition_id}")
    rescue NotFound
      begin
        get_clob("/markets/#{condition_id}")
      rescue NotFound
        nil
      end
    end

    def parse_market(gamma, clob_market: {}, condition_id: nil, event_tags: [], event_title: nil)
      gamma ||= {}
      clob_market ||= {}

      outcomes = parse_array(value_at(gamma, "outcomes"))
      token_ids = parse_array(value_at(gamma, "clobTokenIds", "clob_token_ids"))
      prices = parse_array(value_at(gamma, "outcomePrices", "outcome_prices"))

      clob_tokens = parse_clob_tokens(clob_market)
      outcomes = clob_tokens.map(&:outcome) if outcomes.blank? && clob_tokens.any?
      token_ids = clob_tokens.map(&:token_id) if token_ids.blank? && clob_tokens.any?

      tokens = outcomes.each_with_index.map do |outcome, index|
        Token.new(
          outcome: outcome.to_s,
          token_id: token_ids[index]&.to_s,
          price: decimal_or_nil(prices[index] || clob_tokens[index]&.price),
          winner: clob_tokens[index]&.winner
        )
      end

      Market.new(
        condition_id: (value_at(gamma, "conditionId", "condition_id") || value_at(clob_market, "condition_id") || condition_id)&.downcase,
        question_id: value_at(gamma, "questionID", "questionId", "question_id") || value_at(clob_market, "question_id"),
        slug: value_at(gamma, "slug", "market_slug") || value_at(clob_market, "market_slug"),
        question: value_at(gamma, "question") || value_at(clob_market, "question"),
        outcomes: outcomes.map(&:to_s),
        clob_token_ids: token_ids.map(&:to_s),
        tokens: tokens,
        end_date: value_at(gamma, "endDate", "endDateIso", "end_date"),
        active: bool_value(value_at(gamma, "active") || value_at(clob_market, "active")),
        closed: bool_value(value_at(gamma, "closed") || value_at(clob_market, "closed")),
        neg_risk: bool_value(value_at(gamma, "negRisk", "neg_risk") || value_at(clob_market, "neg_risk")),
        volume_num: decimal_or_nil(value_at(gamma, "volumeNum", "volume_num", "volume")),
        accepting_orders: bool_value(value_at(gamma, "acceptingOrders", "accepting_orders") || value_at(clob_market, "accepting_orders")),
        enable_order_book: bool_value(value_at(gamma, "enableOrderBook", "enable_order_book")),
        collateral_token: normalize_address(value_at(gamma, "collateralToken", "collateral_token")) || PUSD,
        tags: event_tags,
        event_title: event_title
      )
    end

    def mainstream_market?(market)
      (Array(market.tags) & MAINSTREAM_TAG_SLUGS).any? ||
        MAINSTREAM_KEYWORDS.any? { |keyword| market_text(market).include?(keyword) }
    end

    def noisy_market?(market)
      (Array(market.tags) & ENTERTAINMENT_TAG_SLUGS).any? ||
        NOISY_KEYWORDS.any? { |keyword| market_text(market).include?(keyword) }
    end

    def market_text(market)
      [ market.question, market.slug, market.event_title, *Array(market.tags) ].join(" ").downcase
    end

    def parse_clob_tokens(payload)
      raw_tokens = value_at(payload, "tokens") || value_at(payload, "t") || []
      Array(raw_tokens).map do |entry|
        Token.new(
          outcome: value_at(entry, "outcome", "o"),
          token_id: (value_at(entry, "token_id", "asset_id", "t")&.to_s),
          price: decimal_or_nil(value_at(entry, "price")),
          winner: bool_value(value_at(entry, "winner"))
        )
      end
    end

    def parse_array(value)
      case value
      when nil
        []
      when Array
        value
      when String
        stripped = value.strip
        return [] if stripped.blank?

        parsed = JSON.parse(stripped)
        parsed.is_a?(Array) ? parsed : [ parsed ]
      else
        [ value ]
      end
    rescue JSON::ParserError
      [ value ]
    end

    def get_gamma(path, params = {})
      get_json(gamma_connection, path, params)
    end

    def get_clob(path, params = {})
      get_json(clob_connection, path, params)
    end

    def get_json(connection, path, params)
      response = connection.get(path, params.compact)
      raise NotFound, path if response.status == 404
      raise Error, "Polymarket API returned #{response.status}" unless response.success?

      JSON.parse(response.body)
    rescue Faraday::Error, JSON::ParserError => e
      raise Error, "Polymarket API fetch failed: #{e.class}: #{e.message}"
    end

    def gamma_connection
      @gamma_connection ||= Faraday.new(url: BASE_GAMMA) do |f|
        f.request :retry, max: 2, interval: 0.25, backoff_factor: 2
        f.options.timeout = TIMEOUT
        f.options.open_timeout = TIMEOUT
      end
    end

    def clob_connection
      @clob_connection ||= Faraday.new(url: BASE_CLOB) do |f|
        f.request :retry, max: 2, interval: 0.25, backoff_factor: 2
        f.options.timeout = TIMEOUT
        f.options.open_timeout = TIMEOUT
      end
    end

    def value_at(hash, *keys)
      return nil unless hash.respond_to?(:[])

      keys.each do |key|
        return hash[key] if hash.key?(key)
        sym = key.to_sym
        return hash[sym] if hash.key?(sym)
      end
      nil
    end

    def decimal_or_nil(value)
      return nil if value.nil? || value == ""

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def bool_value(value)
      return value if value == true || value == false
      return nil if value.nil?

      value.to_s == "true"
    end

    def normalize_condition_id(value)
      hex = value.to_s.strip.downcase
      raise ArgumentError, "condition_id required" if hex.blank?

      hex.start_with?("0x") ? hex : "0x#{hex}"
    end

    def normalize_address(value)
      return nil if value.blank?

      address = value.to_s.downcase
      address.match?(/\A0x[0-9a-f]{40}\z/) ? address : nil
    end
  end
end
