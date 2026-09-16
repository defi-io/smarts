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

  test "native_symbol returns BNB for bnb" do
    assert_equal "BNB", Chain.new(slug: "bnb").native_symbol
  end

  test "native_symbol returns MATIC for polygon" do
    assert_equal "MATIC", Chain.new(slug: "polygon").native_symbol
  end

  test "native_symbol falls back to ETH for unknown slugs" do
    assert_equal "ETH", Chain.new(slug: "solana").native_symbol
  end

  test "etherscan_url returns the chain-specific explorer api url" do
    chain = Chain.new(explorer_api_url: "https://api.basescan.org/api")

    assert_equal "https://api.basescan.org/api", chain.etherscan_url
  end

  test "tier defaults to full" do
    assert_equal "full", Chain.new.tier
    assert chains(:ethereum).full?
    assert_not chains(:ethereum).docs_only?
  end

  test "network_kind defaults to mainnet" do
    assert_equal "mainnet", Chain.new.network_kind
    assert chains(:ethereum).mainnet?
    assert_not chains(:ethereum).testnet?
  end

  test "network_kind scopes return matching chains" do
    assert_includes Chain.mainnet, chains(:ethereum)
    assert_empty Chain.testnet

    testnet_chain = Chain.create!(
      name: "Sepolia",
      slug: "sepolia",
      chain_id: 11,
      explorer_api_url: "https://api.etherscan.io/v2/api",
      network_kind: "testnet"
    )

    assert_includes Chain.testnet, testnet_chain
    assert testnet_chain.testnet?
    assert_not testnet_chain.mainnet?
  end

  test "tier scopes return matching chains" do
    assert_includes Chain.full, chains(:ethereum)
    assert_empty Chain.docs_only

    docs_chain = Chain.create!(
      name: "Linea", slug: "linea", chain_id: 59144,
      explorer_api_url: "https://api.etherscan.io/v2/api",
      tier: "docs_only"
    )
    assert_includes Chain.docs_only, docs_chain
    assert docs_chain.docs_only?
    assert_not docs_chain.full?
  end

  test "explorer_client returns EtherscanClient for Etherscan-indexed chains" do
    assert_instance_of EtherscanClient, chains(:ethereum).explorer_client
    assert_instance_of EtherscanClient, chains(:polygon).explorer_client
  end

  test "explorer_client returns BlockscoutClient for Robinhood Chain" do
    assert_instance_of BlockscoutClient, chains(:robinhood).explorer_client
  end

  test "explorer_client returns SourcifyClient for Arc" do
    assert_instance_of SourcifyClient, chains(:arc).explorer_client
  end

  # Arc pays gas in native USDC rather than a volatile L1 coin, so the balance
  # display must not fall back to the "ETH" default.
  test "native_symbol is USDC on Arc" do
    assert_equal "USDC", chains(:arc).native_symbol
  end

  # testnet.arcscan.app is a hosted Blockscout behind a vanity domain — the
  # host never says "blockscout", so this would otherwise fall through to
  # EtherscanClient and query a chain Etherscan does not index.
  test "explorer_client returns BlockscoutClient for the Arc testnet vanity host" do
    chain = Chain.new(slug: "arc-testnet", chain_id: 5_042_002, explorer_api_url: "https://testnet.arcscan.app/api")

    assert_instance_of BlockscoutClient, chain.explorer_client
  end

  test "every seeded chain resolves to an explorer client" do
    load Rails.root.join("db/seeds/chains.rb")
    CHAIN_SEEDS.each do |attrs|
      chain = Chain.new(attrs.slice(:name, :slug, :chain_id, :explorer_api_url, :rpc_url))
      assert_kind_of ExplorerClient, chain.explorer_client, "no explorer client for #{attrs[:slug]}"
    end
  end

  test "DISPLAY_ORDER covers every chain in db/seeds/chains.rb" do
    load Rails.root.join("db/seeds/chains.rb")
    seeded_slugs = CHAIN_SEEDS.map { |c| c[:slug] }
    missing = seeded_slugs - Chain::DISPLAY_ORDER
    assert_empty missing,
                 "Seeded chains not listed in Chain::DISPLAY_ORDER: #{missing.inspect}. " \
                 "Add them so they appear in the homepage chain selector."
  end

  test "for_display scope returns chains in DISPLAY_ORDER" do
    Chains::Seeder.call
    slugs = Chain.for_display.pluck(:slug)
    expected = Chain::DISPLAY_ORDER & slugs
    assert_equal expected, slugs
  end
end
