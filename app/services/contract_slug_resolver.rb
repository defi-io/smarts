# Friendly slug resolver for curated contracts.
#
# Slug data is persisted on contracts.catalog_slug and seeded from
# db/seeds/chain_contracts.rb. This service intentionally does not keep a
# parallel slug/address map.
module ContractSlugResolver
  CHAIN_SUFFIX = %w[eth base arbitrum optimism bnb polygon arc].freeze

  # Shared route constraint so routing rejects `/about`, `/api`, etc. Rails
  # anchors constraints internally and rejects \A / \z.
  ROUTE_PATTERN = /[a-z0-9-]+-(?:#{CHAIN_SUFFIX.join('|')})/

  def self.resolve(slug)
    return nil if slug.blank?

    contract = Contract.includes(:chain).find_by(catalog_slug: slug) if catalog_ready?
    return [ contract.chain.slug, contract.address ] if contract

    row = seed_slug_rows.find { |attrs| attrs.fetch(:slug) == slug }
    row && [ row.fetch(:chain_slug), row.fetch(:address) ]
  end

  def self.for(chain_slug, address)
    return nil if chain_slug.blank? || address.blank?

    if catalog_ready?
      chain = Chain.find_by(slug: chain_slug)
      contract = Contract.find_by(chain: chain, address: address.to_s.downcase) if chain
      return contract.catalog_slug if contract&.catalog_slug.present?
    end

    seed_slug_rows.reverse.find do |attrs|
      attrs.fetch(:chain_slug) == chain_slug && attrs.fetch(:address) == address.to_s.downcase
    end&.fetch(:slug)
  end

  def self.canonical_for_slug(slug)
    lookup = resolve(slug)
    return nil unless lookup

    self.for(lookup[0], lookup[1])
  end

  def self.polymarket_slugs
    canonical_slugs.select { |slug| slug.start_with?("polymarket-") }
  end

  # Canonical slug list in registry order. Used for sitemap generation and
  # homepage discovery surfaces.
  def self.canonical_slugs(limit = nil)
    slugs = if catalog_ready? && Contract.where.not(catalog_slug: nil).exists?
      Contract.joins(:chain)
              .where.not(catalog_slug: nil)
              .order(Arel.sql("chains.display_order ASC NULLS LAST"), Arel.sql("contracts.catalog_order ASC NULLS LAST"), :catalog_slug)
              .pluck(:catalog_slug)
    else
      seed_slug_rows.each_with_object({}) do |attrs, acc|
        acc[[ attrs.fetch(:chain_slug), attrs.fetch(:address) ]] = attrs.fetch(:slug)
      end.values
    end

    limit ? slugs.first(limit) : slugs
  end

  def self.seed_slug_rows
    load Rails.root.join("db/seeds/chain_contracts.rb") unless defined?(CONTRACT_SLUG_SEEDS)
    CONTRACT_SLUG_SEEDS
  end
  private_class_method :seed_slug_rows

  def self.catalog_ready?
    Contract.column_names.include?("catalog_slug")
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
    false
  end
  private_class_method :catalog_ready?
end
