require "test_helper"

class ContractsControllerTest < ActionDispatch::IntegrationTest
  test "show renders existing contract" do
    contract = contracts(:uni_token)
    get contract_path(chain: "eth", address: contract.address)

    assert_response :success
    assert_select "h1", "Uni"
  end

  test "show fetches from etherscan when contract not in db" do
    stub_etherscan_full

    get contract_path(chain: "eth", address: "0xdac17f958d2ee523a2206206994597c13d831ec7")

    assert_response :success
    assert_select "h1", "TetherToken"
    assert Contract.exists?(address: "0xdac17f958d2ee523a2206206994597c13d831ec7")
  end

  test "show returns 404 for unverified contract" do
    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200,
      body: { "status" => "1", "message" => "OK", "result" => [ { "ABI" => "Contract source code not verified" } ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    get contract_path(chain: "eth", address: "0x0000000000000000000000000000000000000001")
    assert_response :not_found
  end

  test "show returns 404 for unknown chain" do
    get contract_path(chain: "solana", address: "0x0000000000000000000000000000000000000001")
    assert_response :not_found
  end

  private

  def stub_etherscan_full
    source_body = {
      "status" => "1", "message" => "OK",
      "result" => [ {
        "ContractName" => "TetherToken",
        "CompilerVersion" => "v0.4.18",
        "SourceCode" => "contract TetherToken {}",
        "ABI" => '[{"type":"function","name":"totalSupply","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"}]',
        "OptimizationUsed" => "1",
        "Runs" => "200",
        "EVMVersion" => "default",
        "LicenseType" => "MIT"
      } ]
    }

    abi_body = {
      "status" => "1", "message" => "OK",
      "result" => '[{"type":"function","name":"totalSupply","inputs":[],"outputs":[{"name":"","type":"uint256"}],"stateMutability":"view"}]'
    }

    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200, body: source_body.to_json, headers: { "Content-Type" => "application/json" }
    )
    stub_request(:get, /api\.etherscan\.io.*getabi/).to_return(
      status: 200, body: abi_body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end
end
