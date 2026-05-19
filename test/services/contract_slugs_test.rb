require "test_helper"

class ContractSlugsTest < ActiveSupport::TestCase
  test "resolve returns [chain, address] for a known slug" do
    chain, address = ContractSlugs.resolve("uni-eth")
    assert_equal "eth", chain
    assert_equal "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984", address
  end

  test "resolve returns nil for an unknown slug" do
    assert_nil ContractSlugs.resolve("nonsense-eth")
    assert_nil ContractSlugs.resolve("")
    assert_nil ContractSlugs.resolve(nil)
  end

  test "for returns the slug for a known (chain, address) pair" do
    assert_equal "uni-eth",
                 ContractSlugs.for("eth", "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    assert_equal "usdc-base",
                 ContractSlugs.for("base", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")
  end

  test "for is case-insensitive on address" do
    assert_equal "uni-eth",
                 ContractSlugs.for("eth", "0x1F9840A85D5af5bf1D1762F925BDADDC4201F984")
  end

  test "for returns nil for an unrecognised (chain, address) pair" do
    assert_nil ContractSlugs.for("eth",     "0xdeadbeef00000000000000000000000000000000")
    assert_nil ContractSlugs.for("solana",  "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    # Right address but wrong chain — the mainnet UNI address on Base is a
    # different contract, so no slug should match
    assert_nil ContractSlugs.for("base",    "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
  end

  # Structural guards — these catch typos + drift when SLUGS.yml / constants
  # are edited later.

  test "registry has enough curated blue-chip shortcuts for v1" do
    assert_operator ContractSlugs::MAP.size, :>=, 54
  end

  test "every slug address is lowercase 0x + 40 hex" do
    ContractSlugs::MAP.each do |slug, (_chain, addr)|
      assert_match(/\A0x[0-9a-f]{40}\z/, addr, "slug #{slug} has malformed address #{addr}")
    end
  end

  test "every slug chain is supported" do
    supported = ContractSlugs::CHAIN_SUFFIX
    ContractSlugs::MAP.each do |slug, (chain, _addr)|
      assert_includes supported, chain, "slug #{slug} uses unsupported chain #{chain.inspect}"
    end
  end

  test "every slug key ends in a known chain suffix" do
    ContractSlugs::MAP.each_key do |slug|
      assert_match ContractSlugs::ROUTE_PATTERN, slug,
                   "slug #{slug.inspect} doesn't match ROUTE_PATTERN — route will not match"
    end
  end

  # Duplicate (chain, address) entries are allowed, but only as intentional
  # rebrand aliases explicitly listed below. An accidental duplicate (copy-
  # paste typo) causes this test to fail loudly with instructions. Adding a
  # new rebrand requires updating both MAP and this whitelist — forcing the
  # author to think about canonical order.
  ALLOWED_ALIAS_COUNTS = {
    # Polygon MATIC → POL rebrand (2024). Order in MAP determines canonical.
    [ "polygon", "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270" ] => 2
  }.freeze

  test "duplicate (chain, address) mappings exist only as intentional rebrand aliases" do
    pairs = ContractSlugs::MAP.values.map { |chain, addr| [ chain, addr.downcase ] }
    duplicates = pairs.tally.reject { |_pair, count| count == 1 }

    assert_equal ALLOWED_ALIAS_COUNTS, duplicates,
      "Unexpected duplicate (chain, address) mappings. Either a typo in ContractSlugs::MAP " \
      "or a new intentional rebrand — if the latter, add it to ALLOWED_ALIAS_COUNTS here."
  end

  # ---------- rebrand alias behavior ----------

  test "both WMATIC legacy slug and WPOL canonical slug resolve to the same contract" do
    legacy    = ContractSlugs.resolve("wmatic-polygon")
    canonical = ContractSlugs.resolve("wpol-polygon")
    assert_equal legacy, canonical
    assert_equal "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270", canonical[1]
  end

  # `ContractSlugs.for` is used by the controller to redirect hex URLs to the
  # canonical slug, by the MCP info card, and by the BreadcrumbList. All of
  # those should land on the current brand (wpol-polygon), not the legacy
  # alias, regardless of which URL the user arrived on.
  test "for returns the last-declared (canonical) slug when an address has aliases" do
    assert_equal "wpol-polygon",
                 ContractSlugs.for("polygon", "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")
  end

  test "ROUTE_PATTERN matches slug-like strings but not random paths" do
    assert_match ContractSlugs::ROUTE_PATTERN, "uni-eth"
    assert_match ContractSlugs::ROUTE_PATTERN, "usdc-base"
    assert_match ContractSlugs::ROUTE_PATTERN, "wmatic-polygon"
    # Multi-hyphen compound slug like univ3-usdc-weth-eth must also match
    assert_match ContractSlugs::ROUTE_PATTERN, "univ3-usdc-weth-eth"

    # Rails anchors constraints, so full-string mismatches like /about,
    # /api, /mcp etc. won't match even though they contain letters.
    refute_match(/\A#{ContractSlugs::ROUTE_PATTERN}\z/, "about")
    refute_match(/\A#{ContractSlugs::ROUTE_PATTERN}\z/, "uni")
    refute_match(/\A#{ContractSlugs::ROUTE_PATTERN}\z/, "uni-solana")
    refute_match(/\A#{ContractSlugs::ROUTE_PATTERN}\z/, "uni-eth/extra")
  end

  test "univ3-usdc-weth-eth resolves to the canonical V3 pool address" do
    chain, address = ContractSlugs.resolve("univ3-usdc-weth-eth")
    assert_equal "eth", chain
    assert_equal "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640", address
  end

  test "curated stablecoin slugs include native multi-chain issuer contracts" do
    assert_equal [ "optimism", "0x0b2c639c533813f4aa9d7837caf62653d097ff85" ],
                 ContractSlugs.resolve("usdc-optimism")
    assert_equal [ "polygon", "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359" ],
                 ContractSlugs.resolve("usdc-polygon")
    assert_equal [ "arbitrum", "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9" ],
                 ContractSlugs.resolve("usdt-arbitrum")
  end

  test "curated protocol slugs include core Uniswap and Aave contracts" do
    assert_equal [ "eth", "0x1f98431c8ad98523631ae4a59f267346ea31f984" ],
                 ContractSlugs.resolve("univ3-factory-eth")
    assert_equal [ "eth", "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2" ],
                 ContractSlugs.resolve("aavev3-pool-eth")
    assert_equal [ "base", "0xa238dd80c259a72e81d7e4664a9801593f98d1c5" ],
                 ContractSlugs.resolve("aavev3-pool-base")
  end

  test "curated protocol slugs include the Polymarket contract family on Polygon" do
    # Exchanges: V1 (USDC.e collateral) and V2 (Polymarket USD collateral) run in parallel
    assert_equal [ "polygon", "0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e" ],
                 ContractSlugs.resolve("polymarket-ctf-exchange-v1-polygon")
    assert_equal [ "polygon", "0xe111180000d2663c0091e4f400237545b87b996b" ],
                 ContractSlugs.resolve("polymarket-ctf-exchange-v2-polygon")

    # Multi-outcome (neg-risk) variants
    assert_equal [ "polygon", "0xc5d563a36ae78145c45a50134d48a1215220f80a" ],
                 ContractSlugs.resolve("polymarket-neg-risk-exchange-v1-polygon")
    assert_equal [ "polygon", "0xd91e80cf2e7be2e162c6513ced06f1dd0da35296" ],
                 ContractSlugs.resolve("polymarket-neg-risk-adapter-polygon")

    # Shared CTF (ERC-1155) and UMA oracle adapters across binary markets
    assert_equal [ "polygon", "0x4d97dcd97ec945f40cf65f87097ace5ea0476045" ],
                 ContractSlugs.resolve("polymarket-conditional-tokens-polygon")
    assert_equal [ "polygon", "0x6a9d222616c90fca5754cd1333cfd9b7fb6a4f74" ],
                 ContractSlugs.resolve("polymarket-uma-adapter-v2-polygon")
  end

  # The reverse lookup is what the contracts controller uses to redirect
  # `/polygon/0x...` hex URLs to `/polymarket-*-polygon`. Confirm a sampling
  # of new Polymarket addresses route there.
  test "for returns Polymarket slugs from canonical addresses" do
    assert_equal "polymarket-ctf-exchange-v2-polygon",
                 ContractSlugs.for("polygon", "0xe111180000d2663c0091e4f400237545b87b996b")
    assert_equal "polymarket-conditional-tokens-polygon",
                 ContractSlugs.for("polygon", "0x4d97dcd97ec945f40cf65f87097ace5ea0476045")
    assert_equal "polymarket-uma-adapter-v3-polygon",
                 ContractSlugs.for("polygon", "0x2f5e3684cb1f318ec51b00edba38d79ac2c0aa9d")
  end
end
