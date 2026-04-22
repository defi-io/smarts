module ChainReader
  class Multicall3Client
    ADDRESS = "0xcA11bde05977b3631167028862bE2a173976CA11"
    AGGREGATE3_SIG = "aggregate3((address,bool,bytes)[])"

    Call = Struct.new(:target, :function, :args, keyword_init: true) do
      def args
        self[:args] || []
      end
    end

    Result = Struct.new(:success, :values, :error, keyword_init: true)

    def self.call(chain:, calls:)
      new(chain).call(calls)
    end

    def initialize(chain)
      @chain = chain
    end

    def call(calls)
      return [] if calls.empty?

      tuples = calls.map do |c|
        [ c.target, true, inner_calldata(c.function, c.args) ]
      end

      agg_data = Base.selector(AGGREGATE3_SIG) +
                 Eth::Abi.encode([ "(address,bool,bytes)[]" ], [ tuples ]).unpack1("H*")

      hex = Base.eth_call_hex(@chain, to: ADDRESS, data: agg_data)
      decoded = Eth::Abi.decode([ "(bool,bytes)[]" ], Base.hex_to_bytes(hex))[0]

      decoded.each_with_index.map { |(success, return_data), i| decode_one(calls[i], success, return_data) }
    end

    private

    def inner_calldata(fn_abi, args)
      sel = Base.selector(Base.function_signature(fn_abi))
      types = Array(fn_abi["inputs"]).map { |i| Base.abi_type_string(i) }
      encoded = types.any? ? Eth::Abi.encode(types, args).unpack1("H*") : ""
      Base.hex_to_bytes(sel + encoded)
    end

    def decode_one(call, success, return_data)
      unless success
        return Result.new(success: false, error: "execution reverted")
      end

      outputs = Array(call.function["outputs"])
      if outputs.empty?
        return Result.new(success: true, values: [])
      end

      types = outputs.map { |o| Base.abi_type_string(o) }
      values = Eth::Abi.decode(types, return_data)
      values = values.map.with_index { |v, i| Base.retag_string_encoding(v, outputs[i]) }
      Result.new(success: true, values: values)
    rescue Eth::Abi::DecodingError => e
      Result.new(success: false, error: "decode failed: #{e.message}")
    end
  end
end
