# frozen_string_literal: true

class ReadContractStateTool < ApplicationTool
  tool_name "read_contract_state"
  description "Read the current on-chain value of a view/pure function. Fetches from the chain (cached 60s) and returns the decoded output. Accepts slug or chain+address."

  input_schema(
    properties: {
      slug:          { type: "string", description: "Curated slug like 'uni-eth'. Alternative to chain+address." },
      chain:         { type: "string", description: "Chain slug. Tier 1 (live data) only: eth, base, arbitrum, optimism, bnb, polygon, robinhood, arc. Tier 2 (docs-only) chains return an error. Required unless `slug` is given." },
      address:       { type: "string", description: "The 0x-prefixed contract address. Required unless `slug` is given." },
      function_name: { type: "string", description: "ABI function name, e.g. 'totalSupply' or 'balanceOf'." },
      args:          { type: "array",  description: "Positional arguments for the function, in ABI order. Addresses as 0x hex strings, integers as integers. Default: []" }
    },
    required: [ "function_name" ]
  )

  class << self
    def payload(function_name:, chain: nil, address: nil, slug: nil, args: [])
      resolved = resolve_contract(chain: chain, address: address, slug: slug, require_full: true)
      return resolved if resolved.is_a?(Hash)

      chain_record, contract = resolved

      result = ChainReader::SingleCaller.call(
        contract: contract,
        function_name: function_name,
        args: Array(args)
      )

      return { error: result.error } unless result.success

      {
        chain: chain_record.slug,
        address: contract.address,
        function_name: function_name,
        values: result.values,
        block_number: result.block_number,
        fetched_at: result.fetched_at&.utc&.iso8601
      }
    rescue ChainReader::SingleCaller::FunctionNotFound => e
      { error: e.message }
    end
  end
end
