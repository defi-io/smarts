module ProtocolAdapters
  class Base
    # Explicit adapter registry in match-priority order. Adding a new adapter
    # means adding both the class and its name here.
    ADAPTER_NAMES = %w[UniswapV3Adapter GenericErc20Adapter].freeze

    def self.adapter_classes
      ADAPTER_NAMES.map { |name| ProtocolAdapters.const_get(name) }
    end

    # Returns a concrete adapter instance if any registered adapter matches,
    # nil otherwise. Detection is cached per contract for a day — pool type
    # never changes post-deploy.
    def self.resolve(contract)
      adapter_classes.each do |adapter|
        cache_key = "protocol_match:#{adapter.type_tag}:#{contract.chain.slug}:#{contract.address}"
        matched = Rails.cache.fetch(cache_key, expires_in: 1.day) { adapter.matches?(contract) }
        return adapter.new(contract) if matched
      end
      nil
    end

    # Subclass interface
    def self.type_tag
      raise NotImplementedError
    end

    def self.matches?(_contract)
      raise NotImplementedError
    end

    def initialize(contract)
      @contract = contract
      @chain = contract.chain
    end

    def protocol_name
      raise NotImplementedError
    end

    def panel_data
      raise NotImplementedError
    end

    # Optional: adapter-specific human-friendly display name for the contract,
    # used as the page H1 / title / breadcrumb / JSON-LD `about.name`.
    # Default nil means "let contract_display_name fall through to on-chain
    # name()/symbol()", which is the right answer for plain ERC-20s. Override
    # in adapters where on-chain name() doesn't exist or isn't descriptive
    # (e.g. Uniswap V3 pools: compose "USDC/WETH 0.05%" from token0/token1/fee).
    def display_name
      nil
    end

    def template_partial
      # Default: protocol_adapters/<type_tag>
      "protocol_adapters/#{self.class.type_tag}"
    end

    private

    attr_reader :contract, :chain
  end
end
