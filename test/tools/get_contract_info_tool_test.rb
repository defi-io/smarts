require "test_helper"

class GetContractInfoToolTest < ActiveSupport::TestCase
  setup do
    @tool = GetContractInfoTool.new
  end

  test "returns error for unknown chain slug" do
    result = @tool.call(chain: "solana", address: "0x0")
    assert_equal "unknown chain: solana", result[:error]
  end

  test "returns error when contract is not indexed" do
    result = @tool.call(chain: "eth", address: "0x" + "0" * 40)
    assert_match(/not found/, result[:error])
  end

  test "returns structured metadata for an indexed contract" do
    contract = contracts(:uni_token)
    result = @tool.call(chain: "eth", address: contract.address)

    assert_equal "Uni", result[:name]
    assert_equal "eth", result[:chain]
    assert_equal contract.address, result[:address]
    assert result.key?(:classification)           # may be nil if fixture ABI is minimal
    assert result.key?(:classification_display)
    assert_kind_of Integer, result[:view_function_count]
    assert_kind_of Integer, result[:write_function_count]
    assert_not_nil result[:verified_at]
  end

  test "resolves classification when the ABI is a full ERC-20" do
    erc20_abi = %w[totalSupply balanceOf(address) transfer(address,uint256)
                   transferFrom(address,address,uint256) approve(address,uint256)
                   allowance(address,address)].map do |sig|
      name, args = sig.split("(")
      arg_types = args.to_s.chomp(")").split(",").reject(&:empty?)
      { "type" => "function", "name" => name,
        "inputs" => arg_types.map { |t| { "type" => t } }, "outputs" => [], "stateMutability" => "view" }
    end
    contract = contracts(:uni_token)
    contract.update!(abi: erc20_abi)

    result = @tool.call(chain: "eth", address: contract.address)
    assert_equal "erc20", result[:classification]
    assert_equal "ERC-20 Token", result[:classification_display]
  end

  test "reports the protocol_adapter tag when an adapter matches" do
    contract = contracts(:uni_token)

    fake_adapter = Class.new(ProtocolAdapters::Base) do
      def self.type_tag; "uniswap_v3_pool"; end
    end.new(contract)

    stub_class_method(ProtocolAdapters::Base, :resolve, ->(_c) { fake_adapter }) do
      result = @tool.call(chain: "eth", address: contract.address)
      assert_equal "uniswap_v3_pool", result[:protocol_adapter]
    end
  end

  test "downcases the incoming address before lookup" do
    contract = contracts(:uni_token)
    mixed = contract.address.upcase.sub(/\A0X/, "0x")

    result = @tool.call(chain: "eth", address: mixed)
    assert_equal "Uni", result[:name]
  end
end
