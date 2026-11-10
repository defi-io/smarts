# DefiLlama's bulk datasets: stablecoin supply, protocol TVL and yield pools.
# (Token prices live in DefiLlamaClient — a different host and a per-address
# API.)
#
# Each dataset is one whole-catalogue download (~0.5 MB stablecoins, ~10 MB
# protocols, ~10 MB pools). Parsing a 10 MB body costs ~35–50 MB of transient
# heap, so it must not happen per request: every dataset is fetched at most
# once per TTL, slimmed down to the fields the tools return (pools also to our
# chains), and kept in an in-process MemoryStore. Solid Cache is skipped on
# purpose — a multi-MB blob written to Postgres every 10 minutes buys nothing
# for a single-process app.
class DefiLlamaDatasets
  class Error < StandardError; end

  TIMEOUT = 20
  TTL = 10.minutes

  STABLECOINS_URL = "https://stablecoins.llama.fi/stablecoins?includePrices=true".freeze
  PROTOCOLS_URL   = "https://api.llama.fi/protocols".freeze
  POOLS_URL       = "https://yields.llama.fi/pools".freeze

  # Our chain slug → DefiLlama chain name. The stablecoins and yields APIs
  # share one naming; the protocols API names two chains differently.
  CHAIN_NAMES = {
    "eth"       => "Ethereum",
    "base"      => "Base",
    "arbitrum"  => "Arbitrum",
    "optimism"  => "OP Mainnet",
    "bnb"       => "BSC",
    "polygon"   => "Polygon",
    "robinhood" => "Robinhood Chain",
    "arc"       => "Arc"
  }.freeze
  PROTOCOL_CHAIN_NAMES = CHAIN_NAMES.merge("optimism" => "Optimism", "bnb" => "Binance").freeze

  # chainTvls keys like "Ethereum-borrowed" / "Base-staking", and the bare
  # cross-chain totals "borrowed" / "staking", are breakdowns, not chains;
  # DefiLlama's headline TVL excludes them.
  TVL_BREAKDOWN_SUFFIX = /(?:\A|-)(?:borrowed|staking|pool2|vesting|OwnTokens|treasury|offers)\z/

  class_attribute :store, default: ActiveSupport::Cache::MemoryStore.new(size: 64.megabytes)

  class << self
    def stablecoins
      fetch_dataset("stablecoins") { slim_stablecoins(get_json(STABLECOINS_URL, "peggedAssets")) }
    end

    def protocols
      fetch_dataset("protocols") { slim_protocols(get_json(PROTOCOLS_URL)) }
    end

    def yield_pools
      fetch_dataset("pools") { slim_pools(get_json(POOLS_URL, "data")) }
    end

    # When the cached copy of a dataset ("stablecoins", "protocols",
    # "pools") was downloaded, or nil if it isn't cached. Tools report it as
    # fetched_at, since the data can be up to TTL old.
    def fetched_at(name)
      store.read(dataset_key(name))&.dig(:fetched_at)
    end

    # DefiLlama chain name → our slug, or the DefiLlama name when we don't
    # support that chain.
    def our_chain(llama_name, names: CHAIN_NAMES)
      names.key(llama_name) || llama_name
    end

    private

    def fetch_dataset(name)
      entry = store.fetch(dataset_key(name), expires_in: TTL, race_condition_ttl: 30.seconds) do
        { fetched_at: Time.current, rows: yield }
      end
      entry[:rows]
    end

    def dataset_key(name)
      "defillama:dataset:#{name}"
    end

    def get_json(url, key = nil)
      response = connection.get(url)
      raise Error, "DefiLlama returned #{response.status} for #{url}" unless response.success?

      body = JSON.parse(response.body)
      key ? body.fetch(key) : body
    rescue Faraday::Error, JSON::ParserError, KeyError => e
      raise Error, "DefiLlama fetch failed: #{e.class}: #{e.message}"
    end

    def connection
      @connection ||= Faraday.new do |f|
        f.request :retry, max: 2, interval: 0.5, backoff_factor: 2
        f.options.timeout = TIMEOUT
        f.options.open_timeout = TIMEOUT
      end
    end

    def slim_stablecoins(assets)
      assets.map do |a|
        peg = a["pegType"]
        {
          name: a["name"],
          symbol: a["symbol"],
          peg_type: peg,
          peg_mechanism: a["pegMechanism"],
          price: a["price"],
          circulating: a.dig("circulating", peg),
          circulating_prev_day: a.dig("circulatingPrevDay", peg),
          circulating_prev_week: a.dig("circulatingPrevWeek", peg),
          chains: (a["chainCirculating"] || {})
                    .filter_map { |chain, v| (amount = v.dig("current", peg)) && [ our_chain(chain), amount ] }
                    .sort_by { |_, amount| -amount }
        }
      end
    end

    def slim_protocols(rows)
      rows.map do |p|
        chain_tvls = (p["chainTvls"] || {}).reject { |k, _| k.match?(TVL_BREAKDOWN_SUFFIX) }
        borrowed = (p["chainTvls"] || {}).select { |k, _| k.end_with?("-borrowed") }.values.sum(&:to_f)
        {
          name: p["name"],
          slug: p["slug"],
          category: p["category"],
          tvl_usd: p["tvl"],
          borrowed_usd: borrowed.zero? ? nil : borrowed,
          change_1d: p["change_1d"],
          change_7d: p["change_7d"],
          url: p["url"],
          chains: chain_tvls.map { |chain, tvl| [ our_chain(chain, names: PROTOCOL_CHAIN_NAMES), tvl ] }
                            .sort_by { |_, tvl| -tvl.to_f }
        }
      end
    end

    def slim_pools(rows)
      supported = CHAIN_NAMES.values.to_set
      rows.select { |p| supported.include?(p["chain"]) }.map do |p|
        {
          pool: p["pool"],
          project: p["project"],
          chain: our_chain(p["chain"]),
          symbol: p["symbol"],
          pool_meta: p["poolMeta"],
          tvl_usd: p["tvlUsd"],
          apy: p["apy"],
          apy_base: p["apyBase"],
          apy_reward: p["apyReward"],
          apy_mean_30d: p["apyMean30d"],
          apy_change_7d: p["apyPct7D"],
          stablecoin: p["stablecoin"],
          il_risk: p["ilRisk"],
          exposure: p["exposure"],
          underlying_tokens: p["underlyingTokens"]
        }
      end
    end
  end
end
