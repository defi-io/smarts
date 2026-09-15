module ChainReader
  class Base
    class RpcError < StandardError; end

    RPC_URL_ENV_KEYS = {
      "robinhood" => "ROBINHOOD_RPC_URL"
    }.freeze

    @clients = {}
    @mutex = Mutex.new

    class << self
      def client_for(chain)
        rpc_url = rpc_url_for(chain)
        @mutex.synchronize do
          @clients[[ chain.slug, rpc_url ]] ||= Eth::Client.create(rpc_url)
        end
      end

      # Keep provider credentials out of the database. A chain-specific
      # environment variable can replace the public seeded endpoint in
      # production while local development continues to work without setup.
      def rpc_url_for(chain, env: ENV)
        env_key = RPC_URL_ENV_KEYS[chain.slug]
        env_key ? env[env_key].presence || chain.rpc_url : chain.rpc_url
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
      rescue ::Eth::Client::RpcError => e
        raise RpcError, rpc_error_message(e)
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
      rescue ::Eth::Client::RpcError => e
        raise RpcError, rpc_error_message(e)
      end

      def selector(signature)
        "0x" + Eth::Util.keccak256(signature).unpack1("H*")[0..7]
      end

      def function_signature(fn_abi)
        types = Array(fn_abi["inputs"]).map { |i| i["type"] }.join(",")
        "#{fn_abi['name']}(#{types})"
      end

      # RPC eth_getLogs — works on any chain with an RPC URL. Returns an
      # array of log hashes in the same shape as Etherscan's getLogs
      # (camelCase keys, hex-encoded values) so EventDecoder can consume
      # them without changes. Note: RPC logs lack `timeStamp`; callers
      # must tolerate nil timestamps.
      def eth_get_logs(chain, address:, topic0: nil, from_block: 0, to_block: "latest")
        filter = {
          address: address,
          from_block: "0x#{from_block.to_i.to_s(16)}",
          to_block: to_block.is_a?(Integer) ? "0x#{to_block.to_s(16)}" : to_block
        }
        filter[:topics] = [ topic0 ] if topic0

        raw = client_for(chain).eth_get_logs(filter)
        result = raw.is_a?(Hash) ? raw["result"] : raw
        raise RpcError, raw.dig("error", "message") || "eth_getLogs failed" if raw.is_a?(Hash) && raw["error"]

        Array(result)
      rescue ::Eth::Client::RpcError => e
        raise RpcError, rpc_error_message(e)
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

      def rpc_error_message(error)
        message = error.message.to_s
        code = error.respond_to?(:code) ? error.code : nil
        code.present? ? "#{code}: #{message}" : message
      end
    end
  end
end
