module ChainReader
  class ViewCaller
    CACHE_TTL = 60.seconds

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
      return {} if fns.empty?

      calls = fns.map do |fn|
        Multicall3Client::Call.new(target: @contract.address, function: fn)
      end

      results =
        begin
          Multicall3Client.call(chain: @chain, calls: calls)
        rescue Base::RpcError, Faraday::Error, Errno::ECONNREFUSED, Timeout::Error => e
          Rails.logger.warn("[ViewCaller] multicall failed, falling back: #{e.class}: #{e.message}")
          read_individually(fns)
        end

      fns.zip(results).to_h { |fn, r| [ Base.function_signature(fn), r ] }
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

    def cache_key
      "view_caller:#{@chain.slug}:#{@contract.address}"
    end
  end
end
