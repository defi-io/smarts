module ChainReader
  class Multicall3Client
    ADDRESS = "0xcA11bde05977b3631167028862bE2a173976CA11"
    AGGREGATE3_SIG = "aggregate3((address,bool,bytes)[])"

    # Multicall3 itself exposes getBlockNumber() — we append it to every batch
    # so callers get the block height that the read happened at without a
    # separate RPC.
    BLOCK_NUMBER_FN = {
      "name" => "getBlockNumber",
      "inputs" => [],
      "outputs" => [ { "type" => "uint256" } ]
    }.freeze

    # On Arbitrum, block.number (and so Multicall3.getBlockNumber) returns an
    # approximate L1 Ethereum block, not the L2 block. ArbSys precompile's
    # arbBlockNumber() is the L2 height that eth_blockNumber reports.
    ARB_SYS_ADDRESS = "0x0000000000000000000000000000000000000064"
    ARB_BLOCK_NUMBER_FN = {
      "name" => "arbBlockNumber",
      "inputs" => [],
      "outputs" => [ { "type" => "uint256" } ]
    }.freeze
    ARBITRUM_CHAIN_IDS = [ 42_161 ].freeze

    Call = Struct.new(:target, :function, :args, keyword_init: true) do
      def args
        self[:args] || []
      end
    end

    Result = Struct.new(:success, :values, :error, keyword_init: true)

    Batch = Struct.new(:block_number, :results, keyword_init: true)

    def self.call(chain:, calls:)
      new(chain).call(calls)
    end

    def initialize(chain)
      @chain = chain
    end

    def call(calls)
      return Batch.new(block_number: nil, results: []) if calls.empty?

      block_call = block_number_call
      augmented = calls + [ block_call ]

      tuples = augmented.map do |c|
        [ c.target, true, inner_calldata(c.function, c.args) ]
      end

      agg_data = Base.selector(AGGREGATE3_SIG) +
                 Eth::Abi.encode([ "(address,bool,bytes)[]" ], [ tuples ]).unpack1("H*")

      hex = Base.eth_call_hex(@chain, to: ADDRESS, data: agg_data)
      decoded = Eth::Abi.decode([ "(bool,bytes)[]" ], Base.hex_to_bytes(hex))[0]

      per_call_decoded = decoded.first(calls.size)
      results = per_call_decoded.each_with_index.map { |(success, return_data), i| decode_one(calls[i], success, return_data) }

      block_number = decode_block_number(decoded.last)

      Batch.new(block_number: block_number, results: results)
    end

    private

    def block_number_call
      if ARBITRUM_CHAIN_IDS.include?(@chain.chain_id)
        Call.new(target: ARB_SYS_ADDRESS, function: ARB_BLOCK_NUMBER_FN)
      else
        Call.new(target: ADDRESS, function: BLOCK_NUMBER_FN)
      end
    end

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
    rescue StandardError => e
      # Pre-0.5 Solidity contracts (e.g. USDT, MKR) return raw bytes32 for
      # functions declared as returning `string`. The dynamic-encoding decode
      # fails, but the data is perfectly valid as a null-padded ASCII string.
      # Try that before giving up — it keeps the whole batch from dying.
      fallback = try_bytes32_string_fallback(outputs, return_data)
      return Result.new(success: true, values: fallback) if fallback

      Result.new(success: false, error: "decode failed: #{e.message}")
    end

    # When a single `string` output fails to decode and the return data is
    # exactly 32 bytes, re-interpret it as a null-padded bytes32 value.
    def try_bytes32_string_fallback(outputs, return_data)
      return nil unless outputs&.length == 1 && outputs[0]["type"] == "string"
      return nil unless return_data.bytesize == 32

      raw = return_data.dup.force_encoding(Encoding::UTF_8)
      cleaned = raw.delete("\x00")
      cleaned.valid_encoding? && !cleaned.empty? ? [ cleaned ] : nil
    rescue StandardError
      nil
    end

    def decode_block_number(tuple)
      success, return_data = tuple
      return nil unless success

      Eth::Abi.decode([ "uint256" ], return_data).first
    rescue Eth::Abi::DecodingError
      nil
    end
  end
end
