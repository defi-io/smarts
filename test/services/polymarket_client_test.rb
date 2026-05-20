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

  test "preserves explicit false booleans from Gamma payloads" do
    stub_request(:get, "https://gamma-api.polymarket.com/markets/slug/#{SLUG}").to_return(
      status: 200,
      body: gamma_market.merge(
        "active" => false,
        "closed" => false,
        "negRisk" => false,
        "acceptingOrders" => false
      ).to_json
    )

    market = PolymarketClient.fetch_market_by_slug(SLUG)

    assert_equal false, market.active
    assert_equal false, market.closed
    assert_equal false, market.neg_risk
    assert_equal false, market.accepting_orders
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

  test "fetch_midpoints posts token IDs and parses decimals" do
    stub = stub_request(:post, "https://clob.polymarket.com/midpoints")
      .with(body: [ { token_id: "101" }, { token_id: "202" } ].to_json)
      .to_return(status: 200, body: { "101" => "0.61", "202" => "0.39" }.to_json)

    result = PolymarketClient.fetch_midpoints([ "101", "202" ])

    assert_equal BigDecimal("0.61"), result["101"]
    assert_equal BigDecimal("0.39"), result["202"]
    assert_requested stub, times: 1
  end

  test "fetch_prices posts token IDs with sides and parses best bid ask decimals" do
    stub = stub_request(:post, "https://clob.polymarket.com/prices")
      .with(body: [
        { token_id: "101", side: "BUY" },
        { token_id: "101", side: "SELL" }
      ].to_json)
      .to_return(status: 200, body: { "101" => { "BUY" => 0.6, "SELL" => 0.62 } }.to_json)

    result = PolymarketClient.fetch_prices([
      { token_id: "101", side: "BUY" },
      { token_id: "101", side: "SELL" }
    ])

    assert_equal BigDecimal("0.6"), result.dig("101", "BUY")
    assert_equal BigDecimal("0.62"), result.dig("101", "SELL")
    assert_requested stub, times: 1
  end

  test "fetch_live_prices combines midpoints and bid ask prices" do
    stub_request(:post, "https://clob.polymarket.com/midpoints")
      .to_return(status: 200, body: { "101" => "0.61" }.to_json)
    stub_request(:post, "https://clob.polymarket.com/prices")
      .to_return(status: 200, body: { "101" => { "BUY" => "0.60", "SELL" => "0.62" } }.to_json)

    result = PolymarketClient.fetch_live_prices([ "101" ])

    assert_equal BigDecimal("0.61"), result.dig("101", :mid_price)
    assert_equal BigDecimal("0.60"), result.dig("101", :best_bid)
    assert_equal BigDecimal("0.62"), result.dig("101", :best_ask)
  end

  test "fetch_markets_by_condition_ids returns slug + question keyed by condition_id" do
    stub_request(:get, "https://gamma-api.polymarket.com/markets")
      .with(query: hash_including("condition_ids" => "#{CONDITION_ID},0xdeadbeef0000000000000000000000000000000000000000000000000000beef"))
      .to_return(status: 200, body: [
        gamma_market.merge("slug" => "btc-200k", "question" => "Will BTC top $200k?")
      ].to_json)

    result = PolymarketClient.fetch_markets_by_condition_ids([
      CONDITION_ID,
      "0xdeadbeef0000000000000000000000000000000000000000000000000000beef"
    ])

    assert_equal "btc-200k", result[CONDITION_ID][:slug]
    assert_equal "Will BTC top $200k?", result[CONDITION_ID][:question]
  end

  test "fetch_markets_by_condition_ids drops malformed ids without aborting" do
    stub_request(:get, "https://gamma-api.polymarket.com/markets")
      .with(query: hash_including("condition_ids" => CONDITION_ID))
      .to_return(status: 200, body: [ gamma_market ].to_json)

    result = PolymarketClient.fetch_markets_by_condition_ids([ CONDITION_ID, "garbage", "0xnothex" ])

    assert_equal 1, result.size
    assert result.key?(CONDITION_ID)
  end

  test "fetch_markets_by_question_ids accepts binary bytes32 question ids" do
    question_id = "0x" + ("34" * 32)
    binary_question_id = [ "34" * 32 ].pack("H*").b

    stub_request(:get, "https://gamma-api.polymarket.com/markets")
      .with(query: hash_including("question_ids" => question_id))
      .to_return(status: 200, body: [ gamma_market ].to_json)

    result = PolymarketClient.fetch_markets_by_question_ids([ binary_question_id ])

    assert_equal SLUG, result[question_id][:slug]
    assert_equal "Will example happen?", result[question_id][:question]
  end

  test "fetch_token_id_index builds a token_id => market hash from the events feed" do
    stub_request(:get, "https://gamma-api.polymarket.com/events")
      .with(query: hash_including("active" => "true", "order" => "volume_24hr"))
      .to_return(status: 200, body: [
        {
          "title" => "BTC markets",
          "tags" => [ { "slug" => "crypto" } ],
          "markets" => [ gamma_market.merge("slug" => "btc-200k", "question" => "Will BTC top $200k?") ]
        }
      ].to_json)

    index = PolymarketClient.fetch_token_id_index

    assert_equal "btc-200k", index["101"].slug
    assert_equal "Yes", index["101"].outcome
    assert_equal "No", index["202"].outcome
    assert_equal "Will BTC top $200k?", index["101"].question
  end

  test "fetch_live_prices returns nil fields when CLOB has no orderbook" do
    stub_request(:post, "https://clob.polymarket.com/midpoints").to_return(status: 404)
    stub_request(:post, "https://clob.polymarket.com/prices").to_return(status: 404)

    result = PolymarketClient.fetch_live_prices([ "101" ])

    assert_equal({ mid_price: nil, best_bid: nil, best_ask: nil }, result["101"])
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
