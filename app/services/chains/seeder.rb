module Chains
  # Idempotent upsert for the chain registry. Reads canonical chain attributes
  # from db/seeds/chains.rb and applies them via find_or_initialize_by + update!
  # so re-running is safe (no duplicates, but metadata changes are picked up).
  #
  # Called from:
  #   - db/seeds.rb              (`bin/rails db:seed` in dev / CI)
  #   - Kamal deploy hook        (production sync without ad-hoc migrations)
  #   - bin/rails runner ...     (manual reseed in prod or staging)
  class Seeder
    SEED_PATH = Rails.root.join("db/seeds/chains.rb")
    CONTRACT_SEED_PATH = Rails.root.join("db/seeds/chain_contracts.rb")

    def self.call
      new.call
    end

    def call
      data = load_chain_data
      data.each_with_index do |attrs, index|
        chain = Chain.find_or_initialize_by(slug: attrs[:slug])
        display_order = Chain::DISPLAY_ORDER.index(attrs[:slug]) || index
        chain.update!(
          {
            summary: "",
            docs_url: nil,
            explorer_url: nil,
            faucet_url: nil,
            verify_url: nil
          }.merge(attrs).merge(display_order: display_order)
        )
      end
      seed_contracts
      data.length
    end

    private

    def load_chain_data
      load(SEED_PATH)
      CHAIN_SEEDS
    end

    def seed_contracts
      load(CONTRACT_SEED_PATH)
      CHAIN_CONTRACT_SEEDS.each do |attrs|
        chain = Chain.find_by!(slug: attrs.fetch(:chain_slug))
        contract = Contract.find_or_initialize_by(chain: chain, address: attrs.fetch(:address).downcase)
        contract.update!(
          catalog_name: attrs.fetch(:name),
          catalog_slug: attrs[:slug],
          catalog_kind: attrs.fetch(:kind),
          catalog_notes: attrs[:notes],
          catalog_order: attrs.fetch(:display_order)
        )
      end
      seed_contract_slugs
      prune_removed_catalog_entries
    end

    def seed_contract_slugs
      CONTRACT_SLUG_SEEDS.each do |attrs|
        chain = Chain.find_by!(slug: attrs.fetch(:chain_slug))
        contract = Contract.find_or_initialize_by(chain: chain, address: attrs.fetch(:address).downcase)
        contract.catalog_slug = attrs.fetch(:slug)
        contract.save!
      end
    end

    # The seed file is the whole catalog: a contract dropped from it loses its
    # catalog listing and slug on the next deploy. The contract row itself
    # (ABI, source) stays, so its hex URL keeps working.
    def prune_removed_catalog_entries
      seeded = (CHAIN_CONTRACT_SEEDS + CONTRACT_SLUG_SEEDS)
               .map { |attrs| [ attrs.fetch(:chain_slug), attrs.fetch(:address).downcase ] }.to_set

      Contract.joins(:chain)
              .where("contracts.catalog_name IS NOT NULL OR contracts.catalog_slug IS NOT NULL")
              .select("contracts.id, contracts.address, chains.slug AS chain_slug")
              .reject { |c| seeded.include?([ c.chain_slug, c.address ]) }
              .then { |stale| Contract.where(id: stale.map(&:id)) }
              .update_all(catalog_name: nil, catalog_slug: nil, catalog_kind: nil, catalog_notes: nil, catalog_order: nil)
    end
  end
end
