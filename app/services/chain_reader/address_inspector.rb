module ChainReader
  # Inspects a raw address via node-level JSON-RPC (not Multicall3, since
  # eth_getCode / eth_getBalance / eth_getTransactionCount aren't contract
  # calls). Used by the not-verified page to tell users *something* about
  # the address they landed on.
  class AddressInspector
    CACHE_TTL = 5.minutes

    Result = Struct.new(:is_contract, :balance_wei, :tx_count, :ens_name, keyword_init: true) do
      def eoa?
        !is_contract
      end

      def balance_eth
        return nil unless balance_wei

        balance_wei.to_f / 1e18
      end
    end

    def self.call(chain:, address:)
      new(chain, address).call
    end

    def initialize(chain, address)
      @chain = chain
      @address = address.to_s.downcase
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { inspect_address }
    rescue StandardError => e
      Rails.logger.warn("[AddressInspector] failed for #{@address}: #{e.class}: #{e.message}")
      Result.new(is_contract: nil, balance_wei: nil, tx_count: nil, ens_name: nil)
    end

    private

    def inspect_address
      code = fetch_code
      balance = fetch_balance
      tx_count = fetch_tx_count
      ens = EnsResolver.call(chain: @chain, address: @address)

      Result.new(
        is_contract: code_has_bytecode?(code),
        balance_wei: balance,
        tx_count: tx_count,
        ens_name: ens
      )
    end

    # eth_getCode returns "0x" for EOAs, "0x<bytecode>" for real contracts,
    # and "0xef0100<delegate>" for EIP-7702 delegated EOAs (post-Pectra).
    def fetch_code
      raw = client.eth_get_code(@address, "latest")
      raw.is_a?(Hash) ? raw["result"] : raw
    rescue StandardError
      nil
    end

    def fetch_balance
      client.get_balance(@address)
    rescue StandardError
      nil
    end

    def fetch_tx_count
      raw = client.eth_get_transaction_count(@address, "latest")
      hex = raw.is_a?(Hash) ? raw["result"] || raw.dig("result") : raw
      hex.is_a?(String) ? hex.to_i(16) : nil
    rescue StandardError
      nil
    end

    # Returns true for a "real" contract (deployed bytecode), false for a
    # plain EOA or an EIP-7702 delegated EOA. Delegated EOAs start with the
    # 0xef0100 designator and have exactly 23 bytes of code — still a wallet,
    # even if authorised to a contract, so not a contract in our sense.
    def code_has_bytecode?(code)
      return nil if code.nil?

      normalized = code.to_s.downcase.sub(/\A0x/, "")
      return false if normalized.empty? || normalized == "0"
      return false if normalized.start_with?("ef0100")

      true
    end

    def client
      Base.client_for(@chain)
    end

    def cache_key
      "address_inspector:#{@chain.slug}:#{@address}"
    end
  end
end
