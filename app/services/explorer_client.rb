# Shared behaviour for block-explorer source/ABI clients.
#
# Two implementations exist: EtherscanClient (Etherscan V2) and
# BlockscoutClient (currently used for Robinhood Chain while Etherscan's new
# index has incomplete proxy coverage).
# Callers reach the right one through `Chain#explorer_client` and rescue the
# error classes defined here, so adding an explorer never touches call sites.
class ExplorerClient
  TIMEOUT = 10

  # Blockscout instances sit behind Cloudflare, which serves a bot-challenge
  # page (HTML, not JSON) to requests whose User-Agent isn't in the classic
  # `Mozilla/5.0 (compatible; …)` shape — a bare "smarts.md/1.0" is challenged.
  # We still identify ourselves honestly inside it. Etherscan doesn't care, so
  # we send the same header everywhere rather than special-casing.
  USER_AGENT = "Mozilla/5.0 (compatible; smarts.md/1.0; +https://smarts.md)".freeze

  # Human-readable explorer name, used in error messages. Subclasses override.
  EXPLORER_NAME = "Explorer".freeze

  class Error < StandardError; end
  class NotVerifiedError < Error; end

  # Minimum wall-clock gap between requests to one explorer. Subclasses set
  # their own; state is per-class, so throttling Etherscan never stalls
  # Blockscout.
  class_attribute :throttle_interval, default: 0.0

  class << self
    def throttle!
      interval = throttle_interval.to_f
      return if interval <= 0

      throttle_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @last_request_monotonic
          elapsed = now - @last_request_monotonic
          sleep(interval - elapsed) if elapsed < interval
        end
        @last_request_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    private

    def throttle_mutex
      @throttle_mutex ||= Mutex.new
    end
  end

  def initialize(chain)
    @chain = chain
  end

  # Whether this explorer can serve logs/getLogs for the chain. Callers fall
  # back to RPC eth_getLogs when it can't.
  def logs_supported?
    false
  end

  private

  def connection
    @connection ||= Faraday.new(url: @chain.explorer_api_url, headers: { "User-Agent" => USER_AGENT }) do |f|
      f.request :retry, max: 2, interval: 0.5, backoff_factor: 2
      f.options.timeout = TIMEOUT
      f.options.open_timeout = TIMEOUT
    end
  end

  # Raw GET → parsed JSON body. Every explorer call funnels through here, so
  # network failures and non-JSON bodies (Cloudflare challenge pages, HTML
  # error pages) always surface as Error rather than escaping as Faraday or
  # JSON exceptions the callers don't rescue.
  def get_body(params)
    self.class.throttle!
    response = connection.get do |req|
      req.params = request_params(params)
    end

    JSON.parse(response.body)
  rescue Faraday::Error => e
    raise Error, "#{explorer_name} request failed: #{e.message}"
  rescue JSON::ParserError => e
    raise Error, "#{explorer_name} returned a non-JSON response: #{e.message}"
  end

  # GET against the explorer's Etherscan-style API. Returns the `result`
  # payload; raises Error on any non-success status.
  def request(params)
    body = get_body(params)

    raise Error, "#{explorer_name} API error: #{body["message"]} - #{body["result"]}" unless body["status"] == "1"

    body["result"]
  end

  def explorer_name
    self.class::EXPLORER_NAME
  end

  def request_params(params)
    params
  end

  # The attribute hash `Contract#update!` expects, built once so both clients
  # stay in sync on keys.
  def contract_attributes(name:, compiler_version:, source_code:, abi:, implementation_address: nil)
    {
      name: name,
      compiler_version: compiler_version,
      source_code: source_code,
      abi: abi,
      natspec: NatSpecExtractor.call(source_code),
      implementation_address: implementation_address,
      verified_at: Time.current
    }
  end
end
