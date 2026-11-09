class DefiLlamaClient
  BASE_URL = "https://coins.llama.fi"
  TIMEOUT = 10

  class Error < StandardError; end

  # DefiLlama's chain slugs differ from ours — map at the boundary.
  CHAIN_SLUG_MAP = {
    "eth"      => "ethereum",
    "base"     => "base",
    "arbitrum" => "arbitrum",
    "optimism" => "optimism",
    "bnb"      => "bsc",
    "polygon"  => "polygon",
    "robinhood" => "robinhood",
    "arc"      => "arc"
  }.freeze

  # Returns {lowercased_address => {"price" => Float, "symbol" => String, "decimals" => Integer, "confidence" => Float}}
  # Prices cached 1 minute in Solid Cache.
  def self.fetch_prices(chain:, addresses:)
    return {} if addresses.empty?

    llama_chain = CHAIN_SLUG_MAP[chain.slug]
    return {} if llama_chain.nil?

    keys = addresses.map { |a| "#{llama_chain}:#{a.downcase}" }
    cache_key = "defillama:prices:#{keys.sort.join(',')}"

    Rails.cache.fetch(cache_key, expires_in: 1.minute) do
      fetch_from_api(keys, addresses)
    end
  end

  def self.fetch_from_api(keys, addresses)
    response = connection.get("/prices/current/#{keys.join(',')}")
    raise Error, "DefiLlama returned #{response.status}" unless response.success?

    coins = JSON.parse(response.body).fetch("coins", {})

    keys.zip(addresses).each_with_object({}) do |(key, addr), acc|
      entry = coins[key]
      acc[addr.downcase] = entry if entry
    end
  rescue Faraday::Error, JSON::ParserError => e
    raise Error, "DefiLlama fetch failed: #{e.class}: #{e.message}"
  end

  def self.connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :retry, max: 2, interval: 0.5, backoff_factor: 2
      f.options.timeout = TIMEOUT
      f.options.open_timeout = TIMEOUT
    end
  end
end
