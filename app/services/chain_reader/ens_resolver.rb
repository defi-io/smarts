module ChainReader
  # Reverse-resolves an Ethereum address to its primary ENS name.
  #
  # Two RPC calls in the happy path:
  #   1. ENS Registry `resolver(namehash("<addr>.addr.reverse"))` → reverse
  #      resolver address
  #   2. ReverseResolver `name(node)` → name string
  # Then forward-verifies by resolving the name back to an address (two more
  # calls) — unverified names return nil per ENSIP-3.
  #
  # Mainnet only — ENS on L2s uses different infrastructure and isn't worth
  # the complexity for this MVP. Returns nil for every non-eth chain.
  class EnsResolver
    REGISTRY = "0x00000000000c2e074ec69a0dfb2997ba6c7d2e1e".freeze

    REGISTRY_RESOLVER_FN = {
      "name" => "resolver",
      "inputs" => [ { "type" => "bytes32" } ],
      "outputs" => [ { "type" => "address" } ]
    }.freeze

    RESOLVER_NAME_FN = {
      "name" => "name",
      "inputs" => [ { "type" => "bytes32" } ],
      "outputs" => [ { "type" => "string" } ]
    }.freeze

    RESOLVER_ADDR_FN = {
      "name" => "addr",
      "inputs" => [ { "type" => "bytes32" } ],
      "outputs" => [ { "type" => "address" } ]
    }.freeze

    ZERO_ADDRESS = "0x0000000000000000000000000000000000000000".freeze
    CACHE_TTL = 1.hour

    def self.call(chain:, address:)
      return nil unless chain.slug == "eth"

      new(chain, address).call
    end

    def initialize(chain, address)
      @chain = chain
      @address = address.to_s.downcase
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { lookup }
    rescue StandardError => e
      Rails.logger.warn("[EnsResolver] failed for #{@address}: #{e.class}: #{e.message}")
      nil
    end

    private

    def lookup
      node = reverse_namehash(@address)
      resolver_addr = fetch_resolver(node)
      return nil if resolver_addr.nil? || resolver_addr == ZERO_ADDRESS

      name = fetch_name(resolver_addr, node)
      return nil if name.to_s.empty?

      # Forward-verify — the ENS spec requires that reverse names match a
      # forward lookup. An unverified name is considered unset.
      forward_addr = forward_resolve(name)
      return nil unless forward_addr.is_a?(String) && forward_addr.downcase == @address

      name
    end

    def fetch_resolver(node)
      call_view(REGISTRY, REGISTRY_RESOLVER_FN, [ node ])&.downcase
    end

    def fetch_name(resolver_addr, node)
      call_view(resolver_addr, RESOLVER_NAME_FN, [ node ])
    end

    def forward_resolve(name)
      node = namehash(name)
      resolver_addr = fetch_resolver(node)
      return nil if resolver_addr.nil? || resolver_addr == ZERO_ADDRESS

      call_view(resolver_addr, RESOLVER_ADDR_FN, [ node ])
    end

    def call_view(to, fn, args)
      types = Array(fn["inputs"]).map { |i| i["type"] }
      calldata = Base.selector(Base.function_signature(fn)) + Eth::Abi.encode(types, args).unpack1("H*")
      hex = Base.eth_call_hex(@chain, to: to, data: calldata)
      Eth::Abi.decode(Array(fn["outputs"]).map { |o| o["type"] }, Base.hex_to_bytes(hex)).first
    rescue Base::RpcError, Eth::Abi::DecodingError
      nil
    end

    # ENS reverse namehash: namehash("<hex_without_0x>.addr.reverse")
    def reverse_namehash(addr)
      namehash("#{addr.sub(/\A0x/, '')}.addr.reverse")
    end

    # Iterative ENS namehash per EIP-137.
    def namehash(name)
      hash = ("\x00" * 32).b
      return hash if name.empty?

      name.split(".").reverse_each do |label|
        hash = Eth::Util.keccak256(hash + Eth::Util.keccak256(label))
      end
      hash
    end

    def cache_key
      "ens_resolver:#{@address}"
    end
  end
end
