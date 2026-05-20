# Friendly slug ↔ (chain, address) mapping for curated blue-chip contracts.
#
# Shape: `{symbol}-{chain}` (e.g. `uni-eth`, `usdc-base`). Only whitelisted
# entries have slugs — everything else addresses via hex at `/:chain/:address`.
# Slug is the canonical form; hex URLs 301 to the slug when one exists.
#
# Aliases: when a token rebrands on-chain (e.g. Polygon MATIC → POL in 2024),
# the new slug is added AFTER the old one. Both slugs continue to resolve
# (so existing links don't break), but REVERSE is built with last-write-wins
# so the canonical slug used in breadcrumbs, MCP cards, and hex → slug
# redirects is the *newest* one. Pages served from the legacy slug still
# emit `<link rel="canonical">` pointing at the new one, so Google converges
# on the current brand without a 301 hop.
module ContractSlugs
  CHAIN_SUFFIX = %w[eth base arbitrum optimism polygon].freeze

  # Slug → [chain_slug, lowercase_address]. Keep this ordered the way we want
  # it to appear in any derived iteration (tests, admin tools, etc.). For
  # aliased addresses, legacy slug first, current canonical last.
  MAP = {
    # Stablecoins & wrapped assets — high-signal for issuer/admin-risk docs.
    "usdc-eth"       => [ "eth",      "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" ],
    "usdt-eth"       => [ "eth",      "0xdac17f958d2ee523a2206206994597c13d831ec7" ],
    "dai-eth"        => [ "eth",      "0x6b175474e89094c44da98b954eedeac495271d0f" ],
    "usde-eth"       => [ "eth",      "0x4c9edd5852cd905f086c759e8383e09bff1e68b3" ],
    "susde-eth"      => [ "eth",      "0x9d39a5de30e57443bff2a8307a4256c8797a3497" ],
    "usds-eth"       => [ "eth",      "0xdc035d45d973e3ec169d2276ddab16f1e407384f" ],
    "pyusd-eth"      => [ "eth",      "0x6c3ea9036406852006290770bedfcaba0e23a0e8" ],
    "frax-eth"       => [ "eth",      "0x853d955acef822db058eb8505911ed77f175b99e" ],
    "lusd-eth"       => [ "eth",      "0x5f98805a4e8be255a32880fdec7f6728c6568ba0" ],
    "weth-eth"       => [ "eth",      "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" ],
    "wbtc-eth"       => [ "eth",      "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599" ],

    # Multi-chain stablecoins. Prefer native issuer contracts over bridged
    # variants where both exist (e.g. native USDC, not USDC.e).
    "usdc-base"      => [ "base",     "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913" ],
    "usdc-arbitrum"  => [ "arbitrum", "0xaf88d065e77c8cc2239327c5edb3a432268e5831" ],
    "usdc-optimism"  => [ "optimism", "0x0b2c639c533813f4aa9d7837caf62653d097ff85" ],
    "usdc-polygon"   => [ "polygon",  "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359" ],
    "usdt-arbitrum"  => [ "arbitrum", "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9" ],
    "usdt-optimism"  => [ "optimism", "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58" ],
    "usdt-polygon"   => [ "polygon",  "0xc2132d05d31c914a87c6611c10748aeb04b58e8f" ],

    # Governance / protocol tokens.
    "uni-eth"        => [ "eth",      "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984" ],
    "link-eth"       => [ "eth",      "0x514910771af9ca656af840dff83e8264ecf986ca" ],
    "aave-eth"       => [ "eth",      "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9" ],
    "comp-eth"       => [ "eth",      "0xc00e94cb662c3520282e6f5717214004a7f26888" ],
    "mkr-eth"        => [ "eth",      "0x9f8f72aa9304c8b593d555f12ef6589cc3a579a2" ],
    "sky-eth"        => [ "eth",      "0x56072c95faa701256059aa122697b133aded9279" ],
    "ldo-eth"        => [ "eth",      "0x5a98fcbea516cf06857215779fd812ca3bef1b32" ],
    "crv-eth"        => [ "eth",      "0xd533a949740bb3306d119cc777fa900ba034cd52" ],
    "bal-eth"        => [ "eth",      "0xba100000625a3754423978a60c9317c58a424e3d" ],
    "ens-eth"        => [ "eth",      "0xc18360217d8f7ab5e7c516566761ea12ce7f9d72" ],
    "arb-arbitrum"   => [ "arbitrum", "0x912ce59144191c1204e64559fe8253a0e49e6548" ],
    "op-optimism"    => [ "optimism", "0x4200000000000000000000000000000000000042" ],
    "aero-base"      => [ "base",     "0x940181a94a35a4569e4529a3cdfb74e38fd98631" ],

    # Core protocol contracts. These are MCP shortcut targets, not ERC-20s.
    "univ3-factory-eth"          => [ "eth", "0x1f98431c8ad98523631ae4a59f267346ea31f984" ],
    "univ3-swaprouter-eth"       => [ "eth", "0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45" ],
    "univ3-nftmanager-eth"       => [ "eth", "0xc36442b4a4522e871399cd717abdd847ab11fe88" ],
    "univ3-quoter-eth"           => [ "eth", "0x61ffe014ba17989e743c5f6cb21bf9697530b21e" ],
    "aavev3-pool-eth"            => [ "eth", "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2" ],
    "aavev3-addresses-provider-eth" => [ "eth", "0x2f39d218133afab8f2b819b1066c7e434ad94e9e" ],
    "aavev3-pool-base"           => [ "base", "0xa238dd80c259a72e81d7e4664a9801593f98d1c5" ],
    "aavev3-pool-arbitrum"       => [ "arbitrum", "0x794a61358d6845594f94dc1db02a252b5b4814ad" ],
    "aavev3-pool-optimism"       => [ "optimism", "0x794a61358d6845594f94dc1db02a252b5b4814ad" ],
    "aavev3-pool-polygon"        => [ "polygon", "0x794a61358d6845594f94dc1db02a252b5b4814ad" ],

    # Polymarket (Polygon mainnet). Two exchange generations run side-by-side
    # as of 2026-05. Both V1 and V2 use the same on-chain pipeline: users
    # transact in `pusd` (Polymarket USD, dual-backed by native USDC + USDC.e
    # via a vault), each exchange bridges through its own `collateral-adapter`
    # into Gnosis CTF (`conditional-tokens`), with USDC.e as the CTF backing
    # for binary markets and `WCOL` (owned by `neg-risk-adapter`) for
    # multi-outcome markets. `neg-risk-operator` is the shim that lets a
    # standard UmaCtfAdapter target the NegRiskAdapter's non-CTF interface.
    # UMA adapter v1/v2 resolve binary markets directly; v3 resolves
    # neg-risk markets via the operator. All three remain referenced by
    # live conditions, so we surface them all rather than gating on "current".
    "polymarket-pusd-polygon"                          => [ "polygon", "0xc011a7e12a19f7b1f670d46f03b03f3342e82dfb" ],
    "polymarket-ctf-exchange-v1-polygon"               => [ "polygon", "0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e" ],
    "polymarket-ctf-exchange-v2-polygon"               => [ "polygon", "0xe111180000d2663c0091e4f400237545b87b996b" ],
    "polymarket-neg-risk-exchange-v1-polygon"          => [ "polygon", "0xc5d563a36ae78145c45a50134d48a1215220f80a" ],
    "polymarket-neg-risk-exchange-v2-polygon"          => [ "polygon", "0xe2222d279d744050d28e00520010520000310f59" ],
    "polymarket-collateral-adapter-polygon"            => [ "polygon", "0xada100874d00e3331d00f2007a9c336a65009718" ],
    "polymarket-neg-risk-collateral-adapter-polygon"   => [ "polygon", "0xada200001000ef00d07553cee7006808f895c6f1" ],
    "polymarket-neg-risk-adapter-polygon"              => [ "polygon", "0xd91e80cf2e7be2e162c6513ced06f1dd0da35296" ],
    "polymarket-neg-risk-operator-polygon"             => [ "polygon", "0x71523d0f655b41e805cec45b17163f528b59b820" ],
    "polymarket-conditional-tokens-polygon"            => [ "polygon", "0x4d97dcd97ec945f40cf65f87097ace5ea0476045" ],
    "polymarket-uma-adapter-v1-polygon"                => [ "polygon", "0x71392e133063cc0d16f40e1f9b60227404bc03f7" ],
    "polymarket-uma-adapter-v2-polygon"                => [ "polygon", "0x6a9d222616c90fca5754cd1333cfd9b7fb6a4f74" ],
    "polymarket-uma-adapter-v3-polygon"                => [ "polygon", "0x2f5e3684cb1f318ec51b00edba38d79ac2c0aa9d" ],

    # High-signal Uniswap V3 pools (compound slug: protocol-token0-token1-chain).
    # If/when we add same-pair-different-fee pools, append fee tier:
    # "univ3-usdc-weth-005-eth" (0.05%), "univ3-usdc-weth-030-eth" (0.3%).
    "univ3-usdc-weth-eth" => [ "eth", "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640" ],
    "univ3-usdt-weth-eth" => [ "eth", "0x11b815efb8f581194ae79006d24e0d814b7697f6" ],
    "univ3-wbtc-weth-eth" => [ "eth", "0xcbcdf9626bc03e24f779434178a73a0b4bad62ed" ],
    "univ3-dai-usdc-eth"  => [ "eth", "0x5777d92f208679db4b9778590fa3cab3ac9e2168" ],

    # Polygon WMATIC → WPOL rebrand (2024). `wmatic-polygon` listed first as
    # a legacy alias so existing inbound links and AI-agent configs keep
    # resolving. `wpol-polygon` listed last so REVERSE picks it as canonical.
    "wmatic-polygon" => [ "polygon",  "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270" ],
    "wpol-polygon"   => [ "polygon",  "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270" ]
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

  def self.polymarket_slugs
    MAP.keys.grep(/\Apolymarket-/)
  end
end
