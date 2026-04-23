# frozen_string_literal: true

class ApplicationTool < ActionTool::Base
  protected

  # Resolves a tool's contract input (either a slug OR chain+address) to a
  # [chain_record, contract] pair. Returns an error hash on any failure —
  # callers should short-circuit when the result is a Hash.
  #
  # Slug wins when both are supplied (friendlier than erroring on conflict).
  def resolve_contract(chain: nil, address: nil, slug: nil)
    if slug.present?
      lookup = ContractSlugs.resolve(slug)
      return { error: "unknown slug: #{slug}" } unless lookup

      chain_slug, address = lookup
    else
      return { error: "either `slug` or both `chain` + `address` required" } if chain.blank? || address.blank?

      chain_slug = chain
    end

    chain_record = Chain.find_by(slug: chain_slug)
    return { error: "unknown chain: #{chain_slug}" } unless chain_record

    normalized_address = address.to_s.downcase
    contract = Contract.find_by(chain: chain_record, address: normalized_address)
    unless contract
      return { error: "contract not indexed — visit https://smarts.md/#{chain_slug}/#{normalized_address} first" }
    end

    [ chain_record, contract ]
  end
end
