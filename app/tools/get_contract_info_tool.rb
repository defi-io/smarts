# frozen_string_literal: true

class GetContractInfoTool < ApplicationTool
  tool_name "get_contract_info"
  description "Get metadata about a verified smart contract: name, compiler, classification, supported adapters, and counts of functions and events."

  arguments do
    required(:chain).filled(:string)
      .description("Chain slug: eth, base, arbitrum, optimism, or polygon.")
    required(:address).filled(:string)
      .description("The 0x-prefixed EVM contract address.")
  end

  def call(chain:, address:)
    chain_record = Chain.find_by(slug: chain)
    return { error: "unknown chain: #{chain}" } unless chain_record

    contract = Contract.find_by(chain: chain_record, address: address.downcase)
    return { error: "contract not found — visit #{chain}/#{address} to have it indexed first" } unless contract

    classification = ContractDocument::Classifier.call(contract)
    adapter = ProtocolAdapters::Base.resolve(contract)

    {
      name: contract.name,
      chain: chain,
      address: contract.address,
      compiler_version: contract.compiler_version,
      classification: classification&.protocol_key,
      classification_display: classification&.display_name,
      protocol_adapter: adapter&.class&.type_tag,
      view_function_count: contract.view_functions.size,
      write_function_count: contract.write_functions.size,
      event_count: contract.events.size,
      verified_at: contract.verified_at&.iso8601
    }
  end
end
