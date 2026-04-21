require "test_helper"

class ContractTest < ActiveSupport::TestCase
  test "validates address presence" do
    contract = Contract.new(chain: chains(:ethereum))
    assert_not contract.valid?
    assert_includes contract.errors[:address], "can't be blank"
  end

  test "validates address uniqueness per chain" do
    existing = contracts(:uni_token)
    duplicate = Contract.new(chain: existing.chain, address: existing.address)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:address], "has already been taken"
  end

  test "same address on different chains is allowed" do
    contract = Contract.new(chain: chains(:base), address: contracts(:uni_token).address, name: "Uni on Base")
    assert contract.valid?
  end

  test "normalizes address to lowercase" do
    contract = Contract.new(chain: chains(:ethereum), address: "0xABCDEF1234567890ABCDEF1234567890ABCDEF12")
    contract.valid?
    assert_equal "0xabcdef1234567890abcdef1234567890abcdef12", contract.address
  end

  test "display_address truncates" do
    contract = contracts(:uni_token)
    assert_equal "0x1f98...f984", contract.display_address
  end

  test "view_functions returns only view/pure functions" do
    contract = contracts(:uni_token)
    funcs = contract.view_functions
    assert_equal 1, funcs.size
    assert_equal "totalSupply", funcs.first["name"]
  end

  test "write_functions returns only nonpayable/payable functions" do
    contract = contracts(:uni_token)
    funcs = contract.write_functions
    assert_equal 1, funcs.size
    assert_equal "approve", funcs.first["name"]
  end

  test "events returns only events" do
    contract = contracts(:uni_token)
    evts = contract.events
    assert_equal 1, evts.size
    assert_equal "Transfer", evts.first["name"]
  end

  test "view_functions returns empty array when abi is nil" do
    contract = contracts(:empty_contract)
    assert_equal [], contract.view_functions
    assert_equal [], contract.write_functions
    assert_equal [], contract.events
  end

  test "natspec_for returns doc hash for known function" do
    contract = contracts(:uni_token)
    contract.update!(natspec: { "functions" => { "transfer" => { "notice" => "Moves tokens." } } })

    assert_equal "Moves tokens.", contract.natspec_for("functions", "transfer")["notice"]
  end

  test "natspec_for returns empty hash for unknown function" do
    contract = contracts(:uni_token)
    assert_equal({}, contract.natspec_for("functions", "nonexistent"))
  end

  test "natspec_for tolerates nil natspec column" do
    contract = contracts(:empty_contract)
    assert_equal({}, contract.natspec_for("functions", "anything"))
  end
end
