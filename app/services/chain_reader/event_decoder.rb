module ChainReader
  # Decodes a raw EVM log into a named event with named args, using the
  # contract's ABI events as the schema.
  #
  # Match strategy: topic[0] = keccak256(event_signature). For non-anonymous
  # events this is canonical; anonymous events have no topic[0] and are
  # currently returned as nil (caller falls back to "Unknown").
  #
  # Indexed args live in topics[1..N] (one 32-byte slot each); non-indexed
  # args are ABI-encoded together in `data`. Dynamic types (string, bytes,
  # arrays) when indexed are stored as keccak256(value) — the original is
  # unrecoverable, so we surface `{ hashed: "0x..." }` instead of guessing.
  class EventDecoder
    Decoded = Struct.new(:event_name, :args, :anonymous, keyword_init: true)

    DYNAMIC_INDEXED_PATTERN = /\A(string|bytes)\z|\[/

    class << self
      # `events_abi`: array of ABI items where type=="event".
      # `log`: a Hash with "topics" (array of hex strings) and "data" (hex).
      # Returns `Decoded` on a clean match, or nil if no event signature in
      # the ABI matches topic[0] (caller decides how to render).
      def call(events_abi:, log:)
        topic0 = log["topics"]&.first&.downcase
        return nil unless topic0

        event_abi = events_abi.find { |e| event_topic0(e) == topic0 }
        return nil unless event_abi

        decode(event_abi, log)
      rescue StandardError => e
        Rails.logger.warn("[EventDecoder] decode failed: #{e.class}: #{e.message}")
        nil
      end

      def event_topic0(event_abi)
        "0x" + Eth::Util.keccak256(event_signature(event_abi)).unpack1("H*")
      end

      def event_signature(event_abi)
        types = Array(event_abi["inputs"]).map { |i| Base.abi_type_string(i) }.join(",")
        "#{event_abi['name']}(#{types})"
      end

      private

      def decode(event_abi, log)
        inputs = Array(event_abi["inputs"])
        indexed = inputs.select { |i| i["indexed"] }
        non_indexed = inputs.reject { |i| i["indexed"] }

        indexed_topics = Array(log["topics"])[1..] || []
        indexed_values = indexed.zip(indexed_topics).map { |input, topic| decode_indexed(input, topic) }

        non_indexed_values = decode_non_indexed(non_indexed, log["data"])

        args = {}
        indexed.zip(indexed_values).each      { |input, val| args[input["name"]] = format_arg(input, val) }
        non_indexed.zip(non_indexed_values).each { |input, val| args[input["name"]] = format_arg(input, val) }

        Decoded.new(event_name: event_abi["name"], args: args, anonymous: event_abi["anonymous"] == true)
      end

      def decode_indexed(input, topic_hex)
        return nil if topic_hex.nil?

        type = input["type"].to_s
        return { hashed: topic_hex } if type.match?(DYNAMIC_INDEXED_PATTERN)

        Eth::Abi.decode([ type ], Base.hex_to_bytes(topic_hex)).first
      rescue StandardError
        { raw: topic_hex }
      end

      def decode_non_indexed(non_indexed_inputs, data_hex)
        return [] if non_indexed_inputs.empty?

        bytes = Base.hex_to_bytes(data_hex.to_s)
        return Array.new(non_indexed_inputs.length) if bytes.empty?

        types = non_indexed_inputs.map { |i| Base.abi_type_string(i) }
        Eth::Abi.decode(types, bytes)
      rescue StandardError
        Array.new(non_indexed_inputs.length)
      end

      # JSON.dump can't serialize integers > 2^53 portably (JS clients lose
      # precision). For unsafe ints, return a string. Apply UTF-8 retag for
      # ABI `string` so binary-tagged bytes don't blow up downstream encoders.
      def format_arg(input, value)
        return nil if value.nil?

        if value.is_a?(Integer) && value.bit_length > 53
          value.to_s
        else
          Base.retag_string_encoding(value, input)
        end
      end
    end
  end
end
