module ChainReader
  class ViewCaller
    CACHE_TTL = 60.seconds
    # Bump this if the cached payload shape changes.
    CACHE_VERSION = "v2"

    # Wraps the {sig => Result} hash with the block_number the multicall
    # observed and a fetched_at timestamp. Quacks like a hash for legacy
    # callers (`@live_values["name()"]` keeps working).
    class Snapshot
      attr_reader :results, :block_number, :fetched_at

      def initialize(results:, block_number:, fetched_at:)
        @results = results
        @block_number = block_number
        @fetched_at = fetched_at
      end

      def [](key)         = @results[key]
      def dig(*keys)      = @results.dig(*keys)
      def keys            = @results.keys
      def values          = @results.values
      def each(&block)    = @results.each(&block)
      def each_pair(&blk) = @results.each_pair(&blk)
      def any?(&block)    = @results.any?(&block)
      def empty?          = @results.empty?
      def size            = @results.size
      def present?        = !@results.empty?
      def blank?          = @results.empty?
    end

    def self.call(contract)
      new(contract).call
    end

    def initialize(contract)
      @contract = contract
      @chain = contract.chain
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { read_all }
    end

    private

    def read_all
      fns = zero_arg_view_functions
      return Snapshot.new(results: {}, block_number: nil, fetched_at: Time.current) if fns.empty?

      calls = fns.map do |fn|
        Multicall3Client::Call.new(target: @contract.address, function: fn)
      end

      block_number, results =
        begin
          batch = Multicall3Client.call(chain: @chain, calls: calls)
          [ batch.block_number, batch.results ]
        rescue Base::RpcError, Faraday::Error, Errno::ECONNREFUSED, Timeout::Error => e
          Rails.logger.warn("[ViewCaller] multicall failed, falling back: #{e.class}: #{e.message}")
          [ safe_block_number, read_individually(fns) ]
        end

      keyed = fns.zip(results).to_h { |fn, r| [ Base.function_signature(fn), r ] }
      Snapshot.new(results: keyed, block_number: block_number, fetched_at: Time.current)
    end

    def read_individually(fns)
      fns.map do |fn|
        data = Base.selector(Base.function_signature(fn))
        begin
          hex = Base.eth_call_hex(@chain, to: @contract.address, data: data)
          outputs = Array(fn["outputs"])
          types = outputs.map { |o| Base.abi_type_string(o) }
          values = types.empty? ? [] : Eth::Abi.decode(types, Base.hex_to_bytes(hex))
          values = values.map.with_index { |v, i| Base.retag_string_encoding(v, outputs[i]) }
          Multicall3Client::Result.new(success: true, values: values)
        rescue => e
          Multicall3Client::Result.new(success: false, error: e.message)
        end
      end
    end

    def zero_arg_view_functions
      @contract.view_functions.select { |fn| Array(fn["inputs"]).empty? }
    end

    def safe_block_number
      Base.eth_block_number(@chain)
    rescue StandardError => e
      Rails.logger.warn("[ViewCaller] eth_blockNumber fallback failed: #{e.class}: #{e.message}")
      nil
    end

    def cache_key
      "view_caller:#{CACHE_VERSION}:#{@chain.slug}:#{@contract.address}"
    end
  end
end
