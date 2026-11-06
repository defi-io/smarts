# frozen_string_literal: true

class GetContractInfoTool < ApplicationTool
  tool_name "get_contract_info"
  description "Get metadata about a verified smart contract: name, compiler, classification, supported adapters, and counts of functions and events. Accepts either a curated slug (uni-eth, usdc-base, …) or chain+address."

  input_schema(
    properties: {
      slug:    { type: "string", description: "Curated slug like 'uni-eth' or 'univ3-usdc-weth-eth'. Alternative to chain+address." },
      chain:   { type: "string", description: "Chain slug. Tier 1 (live data): eth, base, arbitrum, optimism, bnb, polygon, robinhood, arc. Tier 2 (source + ABI only): linea, unichain, berachain, blast, sonic, mantle, gnosis, celo, fraxtal, taiko, world, abstract. Required unless `slug` is given." },
      address: { type: "string", description: "The 0x-prefixed EVM contract address. Required unless `slug` is given." }
    }
  )

  class << self
    def payload(chain: nil, address: nil, slug: nil)
      resolved = resolve_contract(chain: chain, address: address, slug: slug)
      return resolved if resolved.is_a?(Hash)

      _chain_record, contract = resolved
      classification = ContractDocument::Classifier.call(contract)
      adapter = ProtocolAdapters::Base.resolve(contract)

      {
        name: contract.name,
        chain: contract.chain.slug,
        address: contract.address,
        slug: ContractSlugResolver.for(contract.chain.slug, contract.address),
        compiler_version: contract.compiler_version,
        classification: classification&.protocol_key,
        classification_display: classification&.display_name,
        protocol_adapter: adapter&.class&.type_tag,
        implementation_address: contract.implementation_address,
        view_function_count: contract.view_functions.size,
        write_function_count: contract.write_functions.size,
        event_count: contract.events.size,
        verified_at: contract.verified_at&.iso8601
      }
    end
  end
end
