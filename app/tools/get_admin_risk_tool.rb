# frozen_string_literal: true

class GetAdminRiskTool < ApplicationTool
  tool_name "get_admin_risk"
  description "Get the current admin / risk profile for a verified contract: detected privileged controls, current control values, recent governance summary, evidence, warnings, and freshness metadata. Accepts either a curated slug or chain+address."

  input_schema(
    properties: {
      slug:    { type: "string", description: "Curated slug like 'usdc-eth' or 'polymarket-ctf-exchange-v2-polygon'. Alternative to chain+address." },
      chain:   { type: "string", description: "Chain slug. Tier 1 (live data) only: eth, base, arbitrum, optimism, bnb, polygon, robinhood, arc. Tier 2 (docs-only) chains return an error. Required unless `slug` is given." },
      address: { type: "string", description: "0x-prefixed EVM contract address. Required unless `slug` is given." }
    }
  )

  class << self
    def payload(chain: nil, address: nil, slug: nil)
      resolved = resolve_contract(chain: chain, address: address, slug: slug, require_full: true)
      return resolved if resolved.is_a?(Hash)

      _chain_record, contract = resolved
      profile = AdminRisk::Profiler.call(contract: contract)

      {
        contract: profile.contract,
        chain: profile.chain,
        slug: ContractSlugResolver.for(profile.chain, profile.contract),
        summary: profile.summary,
        risk_flags: profile.risk_flags,
        controls: profile.controls,
        recent_governance: profile.recent_governance,
        evidence: profile.evidence,
        warnings: profile.warnings,
        block_number: profile.block_number,
        fetched_at: profile.fetched_at&.utc&.iso8601,
        error: profile.error
      }
    end
  end
end
