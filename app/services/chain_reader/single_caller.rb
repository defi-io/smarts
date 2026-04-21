module ChainReader
  # Reads a single view/pure function from a contract. Use this when you need
  # one specific call with optional args — ViewCaller handles batch reading of
  # all zero-arg functions, this one is tighter and supports arguments.
  class SingleCaller
    CACHE_TTL = 60.seconds

    Result = Struct.new(:success, :values, :error, :block_number, keyword_init: true) do
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

      outputs = Array(fn["outputs"])
      types = outputs.map { |o| Base.abi_type_string(o) }
      values = types.empty? ? [] : Eth::Abi.decode(types, Base.hex_to_bytes(hex))

      Result.new(success: true, values: values, error: nil, block_number: nil)
    rescue FunctionNotFound => e
      raise e
    rescue Eth::Abi::DecodingError, Base::RpcError => e
      Result.new(success: false, values: nil, error: e.message, block_number: nil)
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

    def cache_key
      "single_caller:#{@chain.slug}:#{@contract.address}:#{@function_name}:#{@args.inspect}"
    end
  end
end
