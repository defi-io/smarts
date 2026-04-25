module ChainReader
  # Reads a single view/pure function from a contract. Use this when you need
  # one specific call with optional args — ViewCaller handles batch reading of
  # all zero-arg functions, this one is tighter and supports arguments.
  class SingleCaller
    CACHE_TTL = 60.seconds
    CACHE_VERSION = "v2"

    Result = Struct.new(:success, :values, :error, :block_number, :fetched_at, keyword_init: true) do
      def value
        values&.first
      end
    end

    class FunctionNotFound < StandardError; end

    def self.call(contract:, function_name:, args: [])
      new(contract, function_name, args).call
    end

    def initialize(contract, function_name, args)
      @contract = contract
      @chain = contract.chain
      @function_name = function_name
      @args = Array(args)
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { perform }
    end

    private

    def perform
      fn = find_function
      calldata = Base.selector(Base.function_signature(fn)) + encoded_args(fn)
      hex = Base.eth_call_hex(@chain, to: @contract.address, data: calldata)
      block_number = safe_block_number

      outputs = Array(fn["outputs"])
      types = outputs.map { |o| Base.abi_type_string(o) }
      values = types.empty? ? [] : Eth::Abi.decode(types, Base.hex_to_bytes(hex))
      values = values.map.with_index { |v, i| Base.retag_string_encoding(v, outputs[i]) }

      Result.new(success: true, values: values, error: nil, block_number: block_number, fetched_at: Time.current)
    rescue FunctionNotFound => e
      raise e
    rescue Eth::Abi::DecodingError, Base::RpcError => e
      Result.new(success: false, values: nil, error: e.message, block_number: nil, fetched_at: Time.current)
    end

    def find_function
      candidates = Array(@contract.abi).select do |item|
        item["type"] == "function" && item["name"] == @function_name
      end
      raise FunctionNotFound, "no function named '#{@function_name}' on contract" if candidates.empty?

      # Match by arity when overloaded
      match = candidates.find { |fn| Array(fn["inputs"]).size == @args.size }
      raise FunctionNotFound, "no '#{@function_name}' variant with #{@args.size} args" unless match

      match
    end

    def encoded_args(fn)
      inputs = Array(fn["inputs"])
      return "" if inputs.empty?

      types = inputs.map { |i| Base.abi_type_string(i) }
      Eth::Abi.encode(types, @args).unpack1("H*")
    end

    # block_number is best-effort: a failed eth_blockNumber RPC must not turn a
    # successful read into a failed result. Catches StandardError to also
    # absorb misconfigured chains (no rpc_url) and other plumbing issues.
    def safe_block_number
      Base.eth_block_number(@chain)
    rescue StandardError => e
      Rails.logger.warn("[SingleCaller] eth_blockNumber failed: #{e.class}: #{e.message}")
      nil
    end

    def cache_key
      "single_caller:#{CACHE_VERSION}:#{@chain.slug}:#{@contract.address}:#{@function_name}:#{@args.inspect}"
    end
  end
end
