require "test_helper"

class PolymarketClientTest < ActiveSupport::TestCase
  CONDITION_ID = "0x" + ("12" * 32)
  SLUG = "will-example-happen"

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "fetch_market_by_slug parses Gamma JSON string fields without floats" do
    stub_request(:get, "https://gamma-api.polymarket.com/markets/slug/#{SLUG}").to_return(
      status: 200,
      body: gamma_market.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    market = PolymarketClient.fetch_market_by_slug(SLUG)

    assert_equal CONDITION_ID, market.condition_id
    assert_equal [ "Yes", "No" ], market.outcomes
    assert_equal [ "101", "202" ], market.clob_token_ids
    assert_equal BigDecimal("0.62"), market.tokens.first.price
    assert_equal BigDecimal("12345.67"), market.volume_num
    assert_equal PolymarketClient::PUSD, market.collateral_token
  end

  test "fetch_market_by_condition_id uses Gamma metadata and CLOB tokens as fallback" do
    gamma = gamma_market.except("outcomes", "clobTokenIds", "outcomePrices")
    stub_request(:get, "https://gamma-api.polymarket.com/markets")
      .with(query: hash_including("condition_ids" => CONDITION_ID, "limit" => "1"))
      .to_return(status: 200, body: [ gamma ].to_json)
    stub_request(:get, "https://clob.polymarket.com/clob-markets/#{CONDITION_ID}")
      .to_return(status: 200, body: {
        "t" => [
          { "t" => "101", "o" => "Yes" },
          { "t" => "202", "o" => "No" }
        ]
      }.to_json)

    market = PolymarketClient.fetch_market_by_condition_id(CONDITION_ID)

    assert_equal [ "Yes", "No" ], market.outcomes
    assert_equal [ "101", "202" ], market.clob_token_ids
    assert_equal "Will example happen?", market.question
  end

  test "fetch_market_by_slug raises not found on 404" do
    stub_request(:get, "https://gamma-api.polymarket.com/markets/slug/missing").to_return(status: 404)

    assert_raises(PolymarketClient::NotFound) do
      PolymarketClient.fetch_market_by_slug("missing")
    end
  end

  test "caches market metadata" do
    stub = stub_request(:get, "https://gamma-api.polymarket.com/markets/slug/#{SLUG}").to_return(
      status: 200,
      body: gamma_market.to_json
    )

    2.times { PolymarketClient.fetch_market_by_slug(SLUG) }

    assert_requested stub, times: 1
  end

  test "fetch_top_markets prefers mainstream event markets over entertainment noise" do
    stub_request(:get, "https://gamma-api.polymarket.com/events")
      .with(query: hash_including("active" => "true", "closed" => "false", "order" => "volume_24hr"))
      .to_return(status: 200, body: [
        event_with_market(
          title: "GTA VI culture markets",
          tags: [ "pop-culture" ],
          market: gamma_market.merge(
            "question" => "New Rihanna Album before GTA VI?",
            "slug" => "new-rhianna-album-before-gta-vi-926",
            "volumeNum" => "9000000"
          )
        ),
        event_with_market(
          title: "Fed decision",
          tags: [ "economy", "finance" ],
          market: gamma_market.merge(
            "question" => "Fed cuts rates in June?",
            "slug" => "fed-cuts-rates-in-june",
            "volumeNum" => "100000"
          )
        )
      ].to_json)

    markets = PolymarketClient.fetch_top_markets(limit: 5)

    assert_equal [ "Fed cuts rates in June?" ], markets.map(&:question)
    assert_equal [ "economy", "finance" ], markets.first.tags
  end

  test "fetch_top_markets excludes celebrity joke politics markets" do
    stub_request(:get, "https://gamma-api.polymarket.com/events")
      .with(query: hash_including("active" => "true", "closed" => "false", "order" => "volume_24hr"))
      .to_return(status: 200, body: [
        event_with_market(
          title: "World elections",
          tags: [ "elections" ],
          market: gamma_market.merge(
            "question" => "Will LeBron James win the 2028 US Presidential Election?",
            "slug" => "will-lebron-james-win-the-2028-us-presidential-election",
            "volumeNum" => "50000000"
          )
        ),
        event_with_market(
          title: "Bitcoin markets",
          tags: [ "crypto" ],
          market: gamma_market.merge(
            "question" => "Bitcoin above $150k on December 31?",
            "slug" => "bitcoin-above-150k-on-december-31",
            "volumeNum" => "100000"
          )
        )
      ].to_json)

    markets = PolymarketClient.fetch_top_markets(limit: 5)

    assert_equal [ "Bitcoin above $150k on December 31?" ], markets.map(&:question)
  end

  private

  def event_with_market(title:, tags:, market:)
    {
      "title" => title,
      "tags" => tags.map { |slug| { "slug" => slug, "label" => slug.titleize } },
      "markets" => [ market.merge("active" => true, "closed" => false) ]
    }
  end

  def gamma_market
    {
      "conditionId" => CONDITION_ID,
      "questionID" => "0x" + ("34" * 32),
      "slug" => SLUG,
      "question" => "Will example happen?",
      "outcomes" => [ "Yes", "No" ].to_json,
      "outcomePrices" => [ "0.62", "0.38" ].to_json,
      "clobTokenIds" => [ "101", "202" ].to_json,
      "endDate" => "2026-12-31T00:00:00Z",
      "active" => true,
      "closed" => false,
      "negRisk" => false,
      "volumeNum" => "12345.67",
      "acceptingOrders" => true,
      "enableOrderBook" => true
    }
  end
end
