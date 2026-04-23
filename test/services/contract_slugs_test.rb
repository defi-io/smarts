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

  test "no duplicate (chain, address) mappings" do
    pairs = ContractSlugs::MAP.values.map { |chain, addr| [ chain, addr.downcase ] }
    assert_equal pairs.length, pairs.uniq.length,
                 "two slugs point at the same contract — ContractSlugs.for would be ambiguous"
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
end
