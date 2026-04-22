require "test_helper"

class ChainTest < ActiveSupport::TestCase
  test "validates required fields" do
    chain = Chain.new
    assert_not chain.valid?
    assert_includes chain.errors[:name], "can't be blank"
    assert_includes chain.errors[:slug], "can't be blank"
    assert_includes chain.errors[:chain_id], "can't be blank"
    assert_includes chain.errors[:explorer_api_url], "can't be blank"
  end

  test "slug must be unique" do
    duplicate = Chain.new(name: "Dup", slug: chains(:ethereum).slug, chain_id: 999, explorer_api_url: "https://example.com")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:slug], "has already been taken"
  end

  test "chain_id must be unique" do
    duplicate = Chain.new(name: "Dup", slug: "dup", chain_id: chains(:ethereum).chain_id, explorer_api_url: "https://example.com")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:chain_id], "has already been taken"
  end

  test "has many contracts" do
    assert_respond_to chains(:ethereum), :contracts
  end

  test "native_symbol returns ETH for eth, base, arbitrum, optimism" do
    %w[eth base arbitrum optimism].each do |slug|
      assert_equal "ETH", Chain.new(slug: slug).native_symbol, "#{slug} should be ETH"
    end
  end

  test "native_symbol returns MATIC for polygon" do
    assert_equal "MATIC", Chain.new(slug: "polygon").native_symbol
  end

  test "native_symbol falls back to ETH for unknown slugs" do
    assert_equal "ETH", Chain.new(slug: "solana").native_symbol
  end
end
