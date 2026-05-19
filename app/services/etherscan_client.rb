class EtherscanClient
  BASE_URL = "https://api.etherscan.io/v2/api"
  TIMEOUT = 10

  # Etherscan free tier caps at 5 req/sec; some accounts see 3/sec. Be
  # conservative — sleep between calls so the TimelineFetcher's per-event-type
  # fan-out doesn't trip the upstream limiter. Set to 0 in tests so stubbed
  # connections don't pay the wall-clock cost.
  cattr_accessor :throttle_interval, default: 0.4

  @throttle_mutex = Mutex.new
  @last_request_monotonic = nil

  class Error < StandardError; end
  class NotVerifiedError < Error; end

  class << self
    def throttle!
      interval = throttle_interval.to_f
      return if interval <= 0

      @throttle_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @last_request_monotonic
          elapsed = now - @last_request_monotonic
          sleep(interval - elapsed) if elapsed < interval
        end
        @last_request_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  def initialize(chain)
    @chain = chain
    @api_key = Rails.application.credentials.dig(:etherscan, :api_key) || ENV["ETHERSCAN_API_KEY"]
  end

  def fetch_contract_info(address)
    source = fetch_source_code(address)

    if source["Proxy"] == "1" && source["Implementation"].present?
      impl_address = source["Implementation"]
      impl_source = fetch_source_code(impl_address)
      impl_abi = fetch_abi(impl_address)

      {
        name: impl_source["ContractName"],
        compiler_version: impl_source["CompilerVersion"],
        source_code: impl_source["SourceCode"],
        abi: impl_abi,
        natspec: NatSpecExtractor.call(impl_source["SourceCode"]),
        implementation_address: impl_address.downcase,
        verified_at: Time.current
      }
    else
      {
        name: source["ContractName"],
        compiler_version: source["CompilerVersion"],
        source_code: source["SourceCode"],
        abi: fetch_abi(address),
        natspec: NatSpecExtractor.call(source["SourceCode"]),
        implementation_address: nil,
        verified_at: Time.current
      }
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
    self.class.throttle!
    response = connection.get do |req|
      req.params = params.merge(chainid: @chain.chain_id, apikey: @api_key)
    end
    body = JSON.parse(response.body)

    return [] if body["status"] == "0" && body["message"].to_s.include?("No records found")

    raise Error, "Etherscan API error: #{body["message"]} - #{body["result"]}" unless body["status"] == "1"

    body["result"]
  end

  def request(params)
    self.class.throttle!
    response = connection.get do |req|
      req.params = params.merge(chainid: @chain.chain_id, apikey: @api_key)
    end

    body = JSON.parse(response.body)

    raise Error, "Etherscan API error: #{body["message"]} - #{body["result"]}" unless body["status"] == "1"

    body["result"]
  end

  def connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :retry, max: 2, interval: 0.5, backoff_factor: 2
      f.options.timeout = TIMEOUT
      f.options.open_timeout = TIMEOUT
    end
  end
end
