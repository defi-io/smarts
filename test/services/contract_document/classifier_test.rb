require "test_helper"

class ContractDocument::ClassifierTest < ActiveSupport::TestCase
  setup do
    @chain = chains(:ethereum)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "returns nil when contract has no ABI" do
    contract = contracts(:empty_contract)
    assert_nil ContractDocument::Classifier.call(contract)
  end

  test "returns nil when no template's required selectors match" do
    contract = build_contract_with_abi([
      abi_fn("foo"), abi_fn("bar"), abi_fn("baz")
    ])
    assert_nil ContractDocument::Classifier.call(contract)
  end

  test "classifies an ERC-20 contract" do
    contract = build_contract_with_abi(erc20_abi)
    result = ContractDocument::Classifier.call(contract)
    assert_equal "erc20", result.protocol_key
  end

  test "classifies a Uniswap V3 Pool via its distinctive selectors" do
    contract = build_contract_with_abi(v3_pool_abi)
    result = ContractDocument::Classifier.call(contract)
    assert_equal "uniswap_v3_pool", result.protocol_key
  end

  test "picks the most specific template when multiple match (lower priority wins)" do
    # A fake V3 pool that also includes the ERC-20 functions — both templates
    # would match as subsets. V3 (priority 10) must win over ERC-20 (priority 100).
    abi = v3_pool_abi + erc20_abi
    contract = build_contract_with_abi(abi)
    assert_equal "uniswap_v3_pool", ContractDocument::Classifier.call(contract).protocol_key
  end

  test "caches the classification per contract" do
    contract = build_contract_with_abi(erc20_abi)

    first_result = ContractDocument::Classifier.call(contract)

    # Destroy the template to prove the second call is served from cache.
    ProtocolTemplate.where(protocol_key: "erc20").destroy_all
    second_result = ContractDocument::Classifier.call(contract)

    assert_equal first_result.id, second_result.id
  end

  test "cache key isolates same address across different chains" do
    base_chain = chains(:base)
    eth_contract = build_contract_with_abi(erc20_abi)
    base_contract = Contract.create!(
      chain: base_chain,
      address: eth_contract.address,
      abi: erc20_abi
    )

    ContractDocument::Classifier.call(eth_contract)
    ContractDocument::Classifier.call(base_contract)

    # After classifying both, destroying the template should still leave each
    # with its own cached result keyed by chain+address.
    ProtocolTemplate.where(protocol_key: "erc20").destroy_all

    assert_equal "erc20", ContractDocument::Classifier.call(eth_contract).protocol_key
    assert_equal "erc20", ContractDocument::Classifier.call(base_contract).protocol_key
  end

  test "returns nil for ABI containing only events and constructor" do
    contract = build_contract_with_abi([
      { "type" => "constructor", "inputs" => [], "stateMutability" => "nonpayable" },
      { "type" => "event", "name" => "Transfer", "inputs" => [] }
    ])

    assert_nil ContractDocument::Classifier.call(contract)
  end

  private

  def abi_fn(name, inputs: [])
    {
      "type" => "function",
      "name" => name,
      "inputs" => inputs.map { |t| { "type" => t } },
      "outputs" => [],
      "stateMutability" => "view"
    }
  end

  def erc20_abi
    [
      abi_fn("totalSupply"),
      abi_fn("balanceOf", inputs: [ "address" ]),
      abi_fn("transfer", inputs: [ "address", "uint256" ]),
      abi_fn("transferFrom", inputs: [ "address", "address", "uint256" ]),
      abi_fn("approve", inputs: [ "address", "uint256" ]),
      abi_fn("allowance", inputs: [ "address", "address" ])
    ]
  end

  def v3_pool_abi
    [
      abi_fn("factory"),
      abi_fn("token0"),
      abi_fn("token1"),
      abi_fn("fee"),
      abi_fn("slot0"),
      abi_fn("tickSpacing"),
      abi_fn("liquidity")
    ]
  end

  def build_contract_with_abi(abi)
    Contract.create!(
      chain: @chain,
      address: "0x" + SecureRandom.hex(20),
      abi: abi
    )
  end
end
