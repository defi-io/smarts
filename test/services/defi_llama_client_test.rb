require "test_helper"

class DefiLlamaClientTest < ActiveSupport::TestCase
  USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  WETH = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"

  setup do
    @eth = chains(:ethereum)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "returns empty hash for empty addresses list" do
    assert_equal({}, DefiLlamaClient.fetch_prices(chain: @eth, addresses: []))
  end

  test "returns empty hash for chain with no DefiLlama slug mapping" do
    unknown_chain = Chain.new(slug: "solana", chain_id: 9999)
    assert_equal({}, DefiLlamaClient.fetch_prices(chain: unknown_chain, addresses: [ USDC ]))
  end

  test "maps Arc and Robinhood Chain to their DefiLlama slugs" do
    arc_usdc = "0x3600000000000000000000000000000000000000"
    { "arc" => "arc", "robinhood" => "robinhood" }.each do |ours, llama|
      stub_request(:get, "https://coins.llama.fi/prices/current/#{llama}:#{arc_usdc}").to_return(
        status: 200,
        body: { "coins" => { "#{llama}:#{arc_usdc}" => { "price" => 1.0, "symbol" => "USDC", "decimals" => 6 } } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      chain = Chain.new(slug: ours, chain_id: 1)
      assert_equal 1.0, DefiLlamaClient.fetch_prices(chain: chain, addresses: [ arc_usdc ])[arc_usdc]["price"], ours
    end
  end

  test "fetches and maps prices by lowercased address" do
    stub_request(:get, %r{coins\.llama\.fi/prices/current/}).to_return(
      status: 200,
      body: {
        "coins" => {
          "ethereum:#{USDC}" => { "price" => 1.0001, "symbol" => "USDC", "decimals" => 6, "confidence" => 0.99 },
          "ethereum:#{WETH}" => { "price" => 2350.5, "symbol" => "WETH", "decimals" => 18, "confidence" => 0.99 }
        }
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = DefiLlamaClient.fetch_prices(chain: @eth, addresses: [ USDC, WETH ])

    assert_equal 2, result.size
    assert_equal 1.0001, result[USDC]["price"]
    assert_equal "WETH", result[WETH]["symbol"]
  end

  test "handles uppercase address inputs by downcasing for lookup key" do
    stub_request(:get, %r{coins\.llama\.fi/prices/current/}).to_return(
      status: 200,
      body: {
        "coins" => {
          "ethereum:#{USDC}" => { "price" => 1.0, "symbol" => "USDC", "decimals" => 6 }
        }
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = DefiLlamaClient.fetch_prices(chain: @eth, addresses: [ USDC.upcase ])

    assert_equal 1, result.size
    assert result.key?(USDC.downcase)
  end

  test "skips addresses whose coins entry is missing from the response" do
    stub_request(:get, %r{coins\.llama\.fi/prices/current/}).to_return(
      status: 200,
      body: { "coins" => { "ethereum:#{USDC}" => { "price" => 1.0, "symbol" => "USDC" } } }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = DefiLlamaClient.fetch_prices(chain: @eth, addresses: [ USDC, WETH ])
    assert_equal [ USDC ], result.keys
  end

  test "raises Error on non-2xx response" do
    stub_request(:get, %r{coins\.llama\.fi/prices/current/}).to_return(status: 500, body: "boom")

    assert_raises(DefiLlamaClient::Error) do
      DefiLlamaClient.fetch_prices(chain: @eth, addresses: [ USDC ])
    end
  end

  test "raises Error on malformed JSON body" do
    stub_request(:get, %r{coins\.llama\.fi/prices/current/}).to_return(status: 200, body: "not json")

    assert_raises(DefiLlamaClient::Error) do
      DefiLlamaClient.fetch_prices(chain: @eth, addresses: [ USDC ])
    end
  end

  test "caches the response for the same address set" do
    stub = stub_request(:get, %r{coins\.llama\.fi/prices/current/}).to_return(
      status: 200,
      body: { "coins" => { "ethereum:#{USDC}" => { "price" => 1.0, "symbol" => "USDC" } } }.to_json
    )

    DefiLlamaClient.fetch_prices(chain: @eth, addresses: [ USDC ])
    DefiLlamaClient.fetch_prices(chain: @eth, addresses: [ USDC ])
    DefiLlamaClient.fetch_prices(chain: @eth, addresses: [ USDC ])

    assert_requested stub, times: 1
  end
end
