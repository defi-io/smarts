# Friendly slug ↔ (chain, address) mapping for curated blue-chip contracts.
#
# Shape: `{symbol}-{chain}` (e.g. `uni-eth`, `usdc-base`). Only whitelisted
# entries have slugs — everything else addresses via hex at `/:chain/:address`.
# Slug is the canonical form; hex URLs 301 to the slug when one exists.
module ContractSlugs
  CHAIN_SUFFIX = %w[eth base arbitrum optimism polygon].freeze

  # Slug → [chain_slug, lowercase_address]. Keep this ordered the way we want
  # it to appear in any derived iteration (tests, admin tools, etc.).
  MAP = {
    # Stablecoins
    "usdc-eth"       => [ "eth",      "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" ],
    "usdt-eth"       => [ "eth",      "0xdac17f958d2ee523a2206206994597c13d831ec7" ],
    "dai-eth"        => [ "eth",      "0x6b175474e89094c44da98b954eedeac495271d0f" ],

    # DEX & Wrapped
    "weth-eth"       => [ "eth",      "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" ],
    "wbtc-eth"       => [ "eth",      "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599" ],

    # Governance
    "uni-eth"        => [ "eth",      "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984" ],
    "link-eth"       => [ "eth",      "0x514910771af9ca656af840dff83e8264ecf986ca" ],
    "aave-eth"       => [ "eth",      "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9" ],

    # DEX pools (compound slug: protocol-token0-token1-chain).
    # If/when we add same-pair-different-fee pools, append fee tier:
    # "univ3-usdc-weth-005-eth" (0.05%), "univ3-usdc-weth-030-eth" (0.3%).
    "univ3-usdc-weth-eth" => [ "eth", "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640" ],

    # Multi-chain
    "usdc-base"      => [ "base",     "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913" ],
    "usdc-arbitrum"  => [ "arbitrum", "0xaf88d065e77c8cc2239327c5edb3a432268e5831" ],
    "wmatic-polygon" => [ "polygon",  "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270" ]
  }.freeze

  REVERSE = MAP.each_with_object({}) do |(slug, (chain, addr)), acc|
    acc[[ chain, addr.downcase ]] = slug
  end.freeze

  # Shared route constraint so routing rejects `/about`, `/api`, etc. — only
  # strings ending in a known chain slug reach the slug route. No anchors —
  # Rails routing anchors constraints internally and rejects \A / \z.
  #
  # The `[a-z0-9-]+` prefix allows internal hyphens (e.g. `univ3-usdc-weth-eth`);
  # Rails' routing regex engine is greedy-with-backtracking, so it picks the
  # trailing chain suffix correctly.
  ROUTE_PATTERN = /[a-z0-9-]+-(?:#{CHAIN_SUFFIX.join('|')})/

  def self.resolve(slug)
    MAP[slug]
  end

  def self.for(chain_slug, address)
    REVERSE[[ chain_slug, address.to_s.downcase ]]
  end
end
