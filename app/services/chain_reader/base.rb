module ChainReader
  class Base
    class RpcError < StandardError; end

    @clients = {}
    @mutex = Mutex.new

    class << self
      def client_for(chain)
        @mutex.synchronize do
          @clients[chain.slug] ||= Eth::Client.create(chain.rpc_url)
        end
      end

      def eth_call_hex(chain, to:, data:)
        raw = client_for(chain).eth_call({ to: to, data: data })
        if raw.is_a?(Hash)
          if raw["error"]
            raise RpcError, "#{raw['error']['code']}: #{raw['error']['message']}"
          end
          raw["result"]
        else
          raw
        end
      end

      # Returns the chain's current block height as an Integer. Used by the
      # ViewCaller fallback path when Multicall3 is unavailable, since the
      # batch normally piggybacks getBlockNumber() onto the aggregate3 call.
      def eth_block_number(chain)
        raw = client_for(chain).eth_block_number
        result =
          if raw.is_a?(Hash)
            raise RpcError, "#{raw.dig('error', 'code')}: #{raw.dig('error', 'message')}" if raw["error"]
            raw["result"]
          else
            raw
          end
        result.to_s.sub(/\A0x/, "").to_i(16)
      end

      def selector(signature)
        "0x" + Eth::Util.keccak256(signature).unpack1("H*")[0..7]
      end

      def function_signature(fn_abi)
        types = Array(fn_abi["inputs"]).map { |i| i["type"] }.join(",")
        "#{fn_abi['name']}(#{types})"
      end

      def hex_to_bytes(hex)
        [ hex.to_s.sub(/\A0x/, "") ].pack("H*")
      end

      # `Eth::Abi.decode` returns ABI `string` values tagged as ASCII-8BIT
      # (binary). Tokens like Arbitrum USDT whose symbol is "USD₮0" then
      # collide with UTF-8 literals in ERB (e.g. an `↗` glyph) and raise
      # Encoding::CompatibilityError. This retags a decoded value to UTF-8
      # when its declared ABI type is `string` and the bytes happen to be
      # valid UTF-8. Non-string types (uint, address, bytes*) are unchanged.
      def retag_string_encoding(value, output)
        return value unless output["type"] == "string" && value.is_a?(String)
        return value if value.encoding == Encoding::UTF_8

        candidate = value.dup.force_encoding(Encoding::UTF_8)
        candidate.valid_encoding? ? candidate : value
      end

      # Recursively builds the canonical ABI type string for an input/output hash.
      # Handles tuples (with components), tuple arrays (tuple[], tuple[N]), and
      # regular scalars. Feed this to Eth::Abi.decode/encode.
      def abi_type_string(io)
        type = io["type"].to_s
        return type unless type.start_with?("tuple")

        components = Array(io["components"])
        inner = "(" + components.map { |c| abi_type_string(c) }.join(",") + ")"
        suffix = type.sub(/\Atuple/, "")
        inner + suffix
      end
    end
  end
end
