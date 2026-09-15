class EtherscanClient < ExplorerClient
  EXPLORER_NAME = "Etherscan".freeze

  # Etherscan free tier caps at 5 req/sec; some accounts see 3/sec. Be
  # conservative — sleep between calls so the TimelineFetcher's per-event-type
  # fan-out doesn't trip the upstream limiter. Set to 0 in tests so stubbed
  # connections don't pay the wall-clock cost.
  self.throttle_interval = 0.4

  # Etherscan V2 free tier only serves logs/getLogs for Ethereum mainnet;
  # every other chain returns NOTOK "Free API access is not supported". The
  # HTTP round-trip + parse costs ~5s per request, so short-circuit upfront.
  # Source/ABI endpoints are multichain on free tier and not gated here.
  LOGS_FREE_TIER_CHAINS = %w[eth].freeze

  def self.logs_supported?(chain)
    LOGS_FREE_TIER_CHAINS.include?(chain.slug)
  end

  def logs_supported?
    self.class.logs_supported?(@chain)
  end

  def fetch_contract_info(address)
    source = fetch_source_code(address)

    if source["Proxy"] == "1" && source["Implementation"].present?
      impl_address = source["Implementation"]
      impl_source = fetch_source_code(impl_address)

      contract_attributes(
        name: impl_source["ContractName"],
        compiler_version: impl_source["CompilerVersion"],
        source_code: impl_source["SourceCode"],
        abi: fetch_abi(impl_address),
        implementation_address: impl_address.downcase
      )
    else
      contract_attributes(
        name: source["ContractName"],
        compiler_version: source["CompilerVersion"],
        source_code: source["SourceCode"],
        abi: fetch_abi(address)
      )
    end
  end

  # Etherscan V2 logs/getLogs. Returns the raw `result` array — undecoded logs
  # with hex-encoded fields (blockNumber, timeStamp, topics, data, …). Decoding
  # is `ChainReader::EventDecoder`'s job; this method stays a thin HTTP wrapper.
  #
  # `sort: "desc"` returns most-recent-first, which matches our "recent N events"
  # use case. `offset` is page size (Etherscan max is 1000); we typically want
  # 1..100. `topic0` lets us filter to one event signature server-side.
  #
  # `status=0 message="No records found"` is normal (empty contract, narrow
  # filter) — we surface it as an empty array, not an exception.
  def get_logs(address:, topic0: nil, from_block: 0, to_block: "latest", page: 1, offset: 50, sort: "desc")
    unless logs_supported?
      raise Error, "Etherscan free-tier logs not supported on #{@chain.slug}; use RPC"
    end

    params = {
      module: "logs",
      action: "getLogs",
      address: address,
      fromBlock: from_block,
      toBlock: to_block,
      page: page,
      offset: offset,
      sort: sort
    }
    params[:topic0] = topic0 if topic0

    cache_key = "etherscan_logs:#{@chain.slug}:#{address.downcase}:#{topic0}:#{from_block}:#{to_block}:#{page}:#{offset}:#{sort}"
    Rails.cache.fetch(cache_key, expires_in: 60.seconds) { request_logs(params) }
  end

  private

  def fetch_source_code(address)
    result = request(module: "contract", action: "getsourcecode", address: address)
    data = result.first

    raise NotVerifiedError, "Contract #{address} is not verified on #{@chain.name}" if data["ABI"] == "Contract source code not verified"

    data
  end

  def fetch_abi(address)
    result = request(module: "contract", action: "getabi", address: address)
    JSON.parse(result)
  end

  def request_logs(params)
    body = get_body(params)

    return [] if body["status"] == "0" && body["message"].to_s.include?("No records found")

    raise Error, "Etherscan API error: #{body["message"]} - #{body["result"]}" unless body["status"] == "1"

    body["result"]
  end

  def request_params(params)
    params = params.dup
    params[:apikey] = api_key if api_key.present?
    params[:chainid] = @chain.chain_id if etherscan_v2?
    params.compact
  end

  def api_key
    @api_key ||= default_api_key
  end

  def default_api_key
    Rails.application.credentials.dig(:etherscan, :api_key) || ENV["ETHERSCAN_API_KEY"]
  end

  def etherscan_v2?
    @chain.explorer_api_url.to_s.include?("/v2/api")
  end
end
