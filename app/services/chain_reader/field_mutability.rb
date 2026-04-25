module ChainReader
  # Classifies a view-function name into how often its on-chain return value
  # is expected to change. Drives whether the UI shows freshness ("Block #N ·
  # 23s ago") next to a live read.
  #
  # The whitelist is deliberately conservative — functions we know are
  # storage-immutable (set in the constructor and never written again).
  # Anything not on the lists is assumed mutable; better to over-mark a value
  # as live than to silently hide that it could change.
  module FieldMutability
    # Functions whose values are fixed at construction. Showing a block
    # timestamp next to "decimals: 6" is just noise.
    IMMUTABLE = %w[
      name symbol decimals
      DOMAIN_SEPARATOR PERMIT_TYPEHASH
      factory token0 token1 fee tickSpacing
      asset underlying
      MAX_UINT
      WETH9 WETH
    ].freeze

    # Functions whose values change rarely (governance / admin actions). We
    # show the block they were read at but not a "X seconds ago" timestamp,
    # because second-level freshness implies they tick along with the chain.
    SLOW = %w[
      owner
      paused deprecated
      pauser blacklister masterMinter rescuer
      upgradedAddress implementation
      maxTotalSupply
    ].freeze

    def self.classify(function_name)
      return :immutable if IMMUTABLE.include?(function_name)
      return :slow      if SLOW.include?(function_name)

      :fast
    end
  end
end
