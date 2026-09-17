require "test_helper"

class Chains::SeederTest < ActiveSupport::TestCase
  test "registers every chain from db/seeds/chains.rb" do
    seeded_count = Chains::Seeder.call

    load Rails.root.join("db/seeds/chains.rb")
    data = CHAIN_SEEDS
    assert_equal data.length, seeded_count
    data.each do |attrs|
      chain = Chain.find_by!(slug: attrs[:slug])
      assert_equal attrs[:name],     chain.name
      assert_equal attrs[:chain_id], chain.chain_id
      assert_equal attrs[:tier],     chain.tier
      assert_equal attrs.fetch(:network_kind, "mainnet"), chain.network_kind
      assert_equal Chain::DISPLAY_ORDER.index(attrs[:slug]), chain.display_order
      assert_equal attrs.fetch(:summary, ""), chain[:summary]
      assert_seeded_value attrs, chain, :docs_url
      assert_seeded_value attrs, chain, :explorer_url
      assert_seeded_value attrs, chain, :faucet_url
      assert_seeded_value attrs, chain, :verify_url
    end
  end

  test "registers curated chain contracts from db/seeds/chain_contracts.rb" do
    Chains::Seeder.call

    load Rails.root.join("db/seeds/chain_contracts.rb")
    assert_equal CHAIN_CONTRACT_SEEDS.length, Contract.for_catalog.count
    canonical_slug_count = CONTRACT_SLUG_SEEDS.map { |attrs| [ attrs.fetch(:chain_slug), attrs.fetch(:address) ] }.uniq.length
    assert_equal canonical_slug_count, Contract.where.not(catalog_slug: nil).count

    CHAIN_CONTRACT_SEEDS.each do |attrs|
      chain = Chain.find_by!(slug: attrs.fetch(:chain_slug))
      contract = Contract.find_by!(chain: chain, address: attrs.fetch(:address).downcase)
      assert_equal attrs.fetch(:name), contract.catalog_name
      if attrs[:slug]
        assert_equal attrs[:slug], contract.catalog_slug
      else
        assert_nil contract.catalog_slug
      end
      assert_equal attrs.fetch(:kind), contract.catalog_kind
      if attrs[:notes]
        assert_equal attrs[:notes], contract.catalog_notes
      else
        assert_nil contract.catalog_notes
      end
      assert_equal attrs.fetch(:display_order), contract.catalog_order
    end

    canonical_slug_by_pair = CONTRACT_SLUG_SEEDS.each_with_object({}) do |attrs, acc|
      acc[[ attrs.fetch(:chain_slug), attrs.fetch(:address) ]] = attrs.fetch(:slug)
    end
    CONTRACT_SLUG_SEEDS.each do |attrs|
      chain = Chain.find_by!(slug: attrs.fetch(:chain_slug))
      contract = Contract.find_by!(chain: chain, address: attrs.fetch(:address).downcase)
      assert_equal canonical_slug_by_pair.fetch([ attrs.fetch(:chain_slug), attrs.fetch(:address) ]), contract.catalog_slug
    end
  end

  test "is idempotent: calling twice produces no duplicates" do
    before = Chain.count
    contract_before = Contract.count
    2.times { Chains::Seeder.call }
    after = Chain.count
    contract_after = Contract.count

    assert_equal before, after if before == Chain.count
    assert_equal contract_before, contract_after if contract_before == Contract.count
    assert_equal Chain.where(slug: "eth").count, 1
  end

  test "updates existing chain metadata when seed file changes" do
    chain = chains(:ethereum)
    chain.update!(name: "Mistyped Ethereum")
    assert_equal "Mistyped Ethereum", chain.reload.name

    Chains::Seeder.call

    assert_equal "Ethereum", chain.reload.name
  end

  test "Arc uses ArcScan links while source and ABI remain on Sourcify" do
    Chains::Seeder.call
    arc = Chain.find_by!(slug: "arc")

    assert_equal "https://sourcify.dev/server", arc.explorer_api_url
    assert_equal "https://arc.etherscan.io", arc.explorer_url
    assert_equal "https://arc.etherscan.io/verifyContract", arc.verify_url
    assert_instance_of SourcifyClient, arc.explorer_client
  end

  test "catalog chains assemble contracts from persisted catalog rows" do
    Chains::Seeder.call
    eth = Chain.find_by!(slug: "eth")
    Contract.find_or_create_by!(chain: eth, address: "0x9999999999999999999999999999999999999999") do |contract|
      contract.catalog_name = "DB Only Contract"
      contract.catalog_kind = "Test"
      contract.catalog_order = 10_000
    end

    contracts = Chains::Catalog.fetch("eth").contracts

    assert_includes contracts.map(&:name), "DB Only Contract"
    assert_equal Contract.for_catalog.where(chain: eth).count, contracts.length
  end

  private

  def assert_seeded_value(attrs, chain, key)
    if attrs.key?(key)
      assert_equal attrs[key], chain.public_send(key)
    else
      assert_nil chain.public_send(key)
    end
  end
end
