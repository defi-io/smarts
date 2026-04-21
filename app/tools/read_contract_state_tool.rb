# frozen_string_literal: true

class ReadContractStateTool < ApplicationTool
  tool_name "read_contract_state"
  description "Read the current on-chain value of a view/pure function. Fetches from the chain (cached 60s) and returns the decoded output."

  arguments do
    required(:chain).filled(:string)
      .description("Chain slug: eth, base, arbitrum, optimism, or polygon.")
    required(:address).filled(:string)
      .description("The 0x-prefixed contract address.")
    required(:function_name).filled(:string)
      .description("ABI function name, e.g. 'totalSupply' or 'balanceOf'.")
    optional(:args).value(:array)
      .description("Positional arguments for the function, in ABI order. Addresses as 0x hex strings, integers as integers. Default: []")
  end

  def call(chain:, address:, function_name:, args: [])
    chain_record = Chain.find_by(slug: chain)
    return { error: "unknown chain: #{chain}" } unless chain_record

    contract = Contract.find_by(chain: chain_record, address: address.downcase)
    return { error: "contract not indexed — visit https://smarts.md/#{chain}/#{address} first" } unless contract

    result = ChainReader::SingleCaller.call(
      contract: contract,
      function_name: function_name,
      args: Array(args)
    )

    if result.success
      { success: true, values: result.values }
    else
      { success: false, error: result.error }
    end
  rescue ChainReader::SingleCaller::FunctionNotFound => e
    { success: false, error: e.message }
  end
end
