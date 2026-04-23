require "test_helper"

class InspectAddressToolTest < ActiveSupport::TestCase
  setup do
    @tool = InspectAddressTool.new
  end

  test "returns error for unknown chain" do
    result = @tool.call(chain: "solana", address: "0xabc")
    assert_match(/unknown chain/, result[:error])
  end

  test "classifies an EOA with balance + tx count + ENS" do
    fake_result = ChainReader::AddressInspector::Result.new(
      is_contract: false, balance_wei: 1_800_000_000_000_000_000, tx_count: 42, ens_name: "vitalik.eth"
    )
    stub_class_method(ChainReader::AddressInspector, :call, ->(**_) { fake_result }) do
      result = @tool.call(chain: "eth", address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")

      assert_equal false, result[:is_contract]
      assert_equal "eoa", result[:kind]
      assert_equal 1_800_000_000_000_000_000, result[:balance][:wei]
      assert_in_delta 1.8, result[:balance][:native], 1e-9
      assert_equal "ETH", result[:balance][:symbol]
      assert_equal 42, result[:tx_count_sent]
      assert_equal "vitalik.eth", result[:ens_name]
    end
  end

  test "classifies a contract and uses the chain's native symbol" do
    fake_result = ChainReader::AddressInspector::Result.new(
      is_contract: true, balance_wei: 0, tx_count: 1, ens_name: nil
    )
    stub_class_method(ChainReader::AddressInspector, :call, ->(**_) { fake_result }) do
      result = @tool.call(chain: "polygon", address: "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")
      assert_equal true, result[:is_contract]
      assert_equal "contract", result[:kind]
      assert_equal "MATIC", result[:balance][:symbol]
    end
  end

  test "kind is nil when RPC inspection fails" do
    fake_result = ChainReader::AddressInspector::Result.new(
      is_contract: nil, balance_wei: nil, tx_count: nil, ens_name: nil
    )
    stub_class_method(ChainReader::AddressInspector, :call, ->(**_) { fake_result }) do
      result = @tool.call(chain: "eth", address: "0x" + "1" * 40)
      assert_nil result[:kind]
      assert_nil result[:is_contract]
    end
  end

  test "downcases the address in output" do
    fake_result = ChainReader::AddressInspector::Result.new(
      is_contract: false, balance_wei: 0, tx_count: 0, ens_name: nil
    )
    stub_class_method(ChainReader::AddressInspector, :call, ->(**_) { fake_result }) do
      result = @tool.call(chain: "eth", address: "0xD8DA6BF26964AF9D7EED9E03E53415D37AA96045")
      assert_equal "0xd8da6bf26964af9d7eed9e03e53415d37aa96045", result[:address]
    end
  end
end
