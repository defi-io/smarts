require "test_helper"

class ContractSlugResolverTest < ActiveSupport::TestCase
  setup do
    Chains::Seeder.call
  end

  test "resolve returns [chain, address] for a known slug" do
    chain, address = ContractSlugResolver.resolve("uni-eth")
    assert_equal "eth", chain
    assert_equal "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984", address
  end

  test "resolve falls back to the seed file when catalog slugs are not persisted" do
    Contract.update_all(catalog_slug: nil)

    assert_equal [ "eth", "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984" ],
                 ContractSlugResolver.resolve("uni-eth")
    assert_equal "wpol-polygon",
                 ContractSlugResolver.for("polygon", "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")
  end

  test "resolve returns nil for an unknown slug" do
    assert_nil ContractSlugResolver.resolve("nonsense-eth")
    assert_nil ContractSlugResolver.resolve("")
    assert_nil ContractSlugResolver.resolve(nil)
  end

  test "for returns the slug for a known chain and address pair" do
    assert_equal "uni-eth",
                 ContractSlugResolver.for("eth", "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    assert_equal "usdc-base",
                 ContractSlugResolver.for("base", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")
  end

  test "for is case-insensitive on address" do
    assert_equal "uni-eth",
                 ContractSlugResolver.for("eth", "0x1F9840A85D5af5bf1D1762F925BDADDC4201F984")
  end

  test "for returns nil for an unrecognised chain and address pair" do
    assert_nil ContractSlugResolver.for("eth", "0xdeadbeef00000000000000000000000000000000")
    assert_nil ContractSlugResolver.for("solana", "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
    assert_nil ContractSlugResolver.for("base", "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")
  end

  test "slug registry is seeded in the database" do
    load Rails.root.join("db/seeds/chain_contracts.rb")

    assert_operator CONTRACT_SLUG_SEEDS.length, :>=, 54
    canonical_slug_count = CONTRACT_SLUG_SEEDS.map { |attrs| [ attrs.fetch(:chain_slug), attrs.fetch(:address) ] }.uniq.length
    assert_equal canonical_slug_count, Contract.where.not(catalog_slug: nil).count
  end

  test "every seeded slug address is lowercase 0x plus 40 hex" do
    load Rails.root.join("db/seeds/chain_contracts.rb")

    CONTRACT_SLUG_SEEDS.each do |attrs|
      assert_match(/\A0x[0-9a-f]{40}\z/, attrs.fetch(:address), "slug #{attrs.fetch(:slug)} has malformed address")
    end
  end

  test "every seeded slug chain is supported by the route suffix set" do
    load Rails.root.join("db/seeds/chain_contracts.rb")

    CONTRACT_SLUG_SEEDS.each do |attrs|
      assert_includes ContractSlugResolver::CHAIN_SUFFIX, attrs.fetch(:chain_slug), "slug #{attrs.fetch(:slug)} uses unsupported chain"
    end
  end

  test "every seeded slug key ends in a known chain suffix" do
    load Rails.root.join("db/seeds/chain_contracts.rb")

    CONTRACT_SLUG_SEEDS.each do |attrs|
      assert_match ContractSlugResolver::ROUTE_PATTERN, attrs.fetch(:slug),
                   "slug #{attrs.fetch(:slug).inspect} does not match ROUTE_PATTERN"
    end
  end

  test "no duplicate canonical slug records exist" do
    duplicates = Contract.where.not(catalog_slug: nil).group(:catalog_slug).count.select { |_slug, count| count > 1 }

    assert_empty duplicates
  end

  test "for returns the canonical WPOL slug" do
    assert_equal [ "polygon", "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270" ],
                 ContractSlugResolver.resolve("wmatic-polygon")
    assert_equal "wpol-polygon",
                 ContractSlugResolver.for("polygon", "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")
  end

  test "ROUTE_PATTERN matches slug-like strings but not random paths" do
    assert_match ContractSlugResolver::ROUTE_PATTERN, "uni-eth"
    assert_match ContractSlugResolver::ROUTE_PATTERN, "usdc-base"
    assert_match ContractSlugResolver::ROUTE_PATTERN, "univ3-usdc-weth-eth"

    refute_match(/\A#{ContractSlugResolver::ROUTE_PATTERN}\z/, "about")
    refute_match(/\A#{ContractSlugResolver::ROUTE_PATTERN}\z/, "uni")
    refute_match(/\A#{ContractSlugResolver::ROUTE_PATTERN}\z/, "uni-solana")
    refute_match(/\A#{ContractSlugResolver::ROUTE_PATTERN}\z/, "uni-eth/extra")
  end

  test "univ3-usdc-weth-eth resolves to the canonical V3 pool address" do
    assert_equal [ "eth", "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640" ],
                 ContractSlugResolver.resolve("univ3-usdc-weth-eth")
  end

  test "curated stablecoin slugs include native multi-chain issuer contracts" do
    assert_equal [ "optimism", "0x0b2c639c533813f4aa9d7837caf62653d097ff85" ],
                 ContractSlugResolver.resolve("usdc-optimism")
    assert_equal [ "polygon", "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359" ],
                 ContractSlugResolver.resolve("usdc-polygon")
    assert_equal [ "arbitrum", "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9" ],
                 ContractSlugResolver.resolve("usdt-arbitrum")
  end

  test "curated protocol slugs include core Uniswap and Aave contracts" do
    assert_equal [ "eth", "0x1f98431c8ad98523631ae4a59f267346ea31f984" ],
                 ContractSlugResolver.resolve("univ3-factory-eth")
    assert_equal [ "eth", "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2" ],
                 ContractSlugResolver.resolve("aavev3-pool-eth")
    assert_equal [ "base", "0xa238dd80c259a72e81d7e4664a9801593f98d1c5" ],
                 ContractSlugResolver.resolve("aavev3-pool-base")
    assert_equal [ "bnb", "0x6807dc923806fe8fd134338eabca509979a7e0cb" ],
                 ContractSlugResolver.resolve("aavev3-pool-bnb")
  end

  test "curated protocol slugs include the Polymarket contract family on Polygon" do
    assert_equal [ "polygon", "0xc011a7e12a19f7b1f670d46f03b03f3342e82dfb" ],
                 ContractSlugResolver.resolve("polymarket-pusd-polygon")
    assert_equal [ "polygon", "0x4bfb41d5b3570defd03c39a9a4d8de6bd8b8982e" ],
                 ContractSlugResolver.resolve("polymarket-ctf-exchange-v1-polygon")
    assert_equal [ "polygon", "0xe111180000d2663c0091e4f400237545b87b996b" ],
                 ContractSlugResolver.resolve("polymarket-ctf-exchange-v2-polygon")
    assert_equal [ "polygon", "0xc5d563a36ae78145c45a50134d48a1215220f80a" ],
                 ContractSlugResolver.resolve("polymarket-neg-risk-exchange-v1-polygon")
    assert_equal [ "polygon", "0xd91e80cf2e7be2e162c6513ced06f1dd0da35296" ],
                 ContractSlugResolver.resolve("polymarket-neg-risk-adapter-polygon")
    assert_equal [ "polygon", "0xada100874d00e3331d00f2007a9c336a65009718" ],
                 ContractSlugResolver.resolve("polymarket-collateral-adapter-polygon")
    assert_equal [ "polygon", "0xada200001000ef00d07553cee7006808f895c6f1" ],
                 ContractSlugResolver.resolve("polymarket-neg-risk-collateral-adapter-polygon")
    assert_equal [ "polygon", "0x71523d0f655b41e805cec45b17163f528b59b820" ],
                 ContractSlugResolver.resolve("polymarket-neg-risk-operator-polygon")
    assert_equal [ "polygon", "0x4d97dcd97ec945f40cf65f87097ace5ea0476045" ],
                 ContractSlugResolver.resolve("polymarket-conditional-tokens-polygon")
    assert_equal [ "polygon", "0x6a9d222616c90fca5754cd1333cfd9b7fb6a4f74" ],
                 ContractSlugResolver.resolve("polymarket-uma-adapter-v2-polygon")
  end

  test "polymarket_slugs returns the full curated Polymarket contract family" do
    slugs = ContractSlugResolver.polymarket_slugs

    assert_includes slugs, "polymarket-ctf-exchange-v2-polygon"
    assert_includes slugs, "polymarket-neg-risk-exchange-v2-polygon"
    assert_includes slugs, "polymarket-conditional-tokens-polygon"
    assert_includes slugs, "polymarket-uma-adapter-v3-polygon"
    assert_operator slugs.length, :>=, 13
    assert slugs.all? { |slug| ContractSlugResolver.resolve(slug)&.first == "polygon" }
  end

  test "for returns Polymarket slugs from canonical addresses" do
    assert_equal "polymarket-pusd-polygon",
                 ContractSlugResolver.for("polygon", "0xc011a7e12a19f7b1f670d46f03b03f3342e82dfb")
    assert_equal "polymarket-ctf-exchange-v2-polygon",
                 ContractSlugResolver.for("polygon", "0xe111180000d2663c0091e4f400237545b87b996b")
    assert_equal "polymarket-conditional-tokens-polygon",
                 ContractSlugResolver.for("polygon", "0x4d97dcd97ec945f40cf65f87097ace5ea0476045")
    assert_equal "polymarket-uma-adapter-v3-polygon",
                 ContractSlugResolver.for("polygon", "0x2f5e3684cb1f318ec51b00edba38d79ac2c0aa9d")
    assert_equal "polymarket-neg-risk-operator-polygon",
                 ContractSlugResolver.for("polygon", "0x71523d0f655b41e805cec45b17163f528b59b820")
  end
end
