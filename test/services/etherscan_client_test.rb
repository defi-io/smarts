require "test_helper"

class EtherscanClientTest < ActiveSupport::TestCase
  setup do
    @chain = chains(:ethereum)
    @client = EtherscanClient.new(@chain)
  end

  test "raises NotVerifiedError for unverified contract" do
    stub_etherscan_source(verified: false)

    assert_raises(EtherscanClient::NotVerifiedError) do
      @client.fetch_contract_info("0x0000000000000000000000000000000000000001")
    end
  end

  test "fetch_contract_info returns parsed data" do
    stub_etherscan_source(verified: true)
    stub_etherscan_abi

    info = @client.fetch_contract_info("0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")

    assert_equal "Uni", info[:name]
    assert_equal "v0.5.16", info[:compiler_version]
    assert_kind_of Array, info[:abi]
    assert_equal 1, info[:abi].size
    assert_not_nil info[:verified_at]
  end

  private

  def stub_etherscan_source(verified:)
    body = if verified
      {
        "status" => "1", "message" => "OK",
        "result" => [ {
          "ContractName" => "Uni",
          "CompilerVersion" => "v0.5.16",
          "SourceCode" => "contract Uni {}",
          "ABI" => '[{"type":"function","name":"totalSupply"}]',
          "OptimizationUsed" => "1",
          "Runs" => "200",
          "EVMVersion" => "default",
          "LicenseType" => "MIT"
        } ]
      }
    else
      {
        "status" => "1", "message" => "OK",
        "result" => [ { "ABI" => "Contract source code not verified" } ]
      }
    end

    stub_request(:get, /api\.etherscan\.io.*getsourcecode/).to_return(
      status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_etherscan_abi
    body = {
      "status" => "1", "message" => "OK",
      "result" => '[{"type":"function","name":"totalSupply"}]'
    }

    stub_request(:get, /api\.etherscan\.io.*getabi/).to_return(
      status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end
end
