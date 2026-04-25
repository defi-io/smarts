# frozen_string_literal: true

class ReadContractStateTool < ApplicationTool
  tool_name "read_contract_state"
  description "Read the current on-chain value of a view/pure function. Fetches from the chain (cached 60s) and returns the decoded output. Accepts slug or chain+address."

  arguments do
    optional(:slug).filled(:string)
      .description("Curated slug like 'uni-eth'. Alternative to chain+address.")
    optional(:chain).filled(:string)
      .description("Chain slug: eth, base, arbitrum, optimism, or polygon. Required unless `slug` is given.")
    optional(:address).filled(:string)
      .description("The 0x-prefixed contract address. Required unless `slug` is given.")
    required(:function_name).filled(:string)
      .description("ABI function name, e.g. 'totalSupply' or 'balanceOf'.")
    optional(:args).value(:array)
      .description("Positional arguments for the function, in ABI order. Addresses as 0x hex strings, integers as integers. Default: []")
  end

  def call(function_name:, chain: nil, address: nil, slug: nil, args: [])
    resolved = resolve_contract(chain: chain, address: address, slug: slug)
    return resolved if resolved.is_a?(Hash)

    _chain_record, contract = resolved

    result = ChainReader::SingleCaller.call(
      contract: contract,
      function_name: function_name,
      args: Array(args)
    )

    if result.success
      { success: true, values: result.values, block_number: result.block_number }
    else
      { success: false, error: result.error }
    end
  rescue ChainReader::SingleCaller::FunctionNotFound => e
    { success: false, error: e.message }
  end
end
