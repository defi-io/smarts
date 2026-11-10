require "test_helper"

class FallbackExplorerClientTest < ActiveSupport::TestCase
  ADDRESS = "0x3600000000000000000000000000000000000000"

  class FakeClient
    def initialize(&behaviour)
      @behaviour = behaviour
      @calls = 0
    end

    attr_reader :calls

    def fetch_contract_info(address)
      @calls += 1
      @behaviour.call(address)
    end
  end

  def not_verified = FakeClient.new { raise ExplorerClient::NotVerifiedError, "not verified" }
  def outage = FakeClient.new { raise ExplorerClient::Error, "rate limited" }
  def verified(name) = FakeClient.new { { name: name } }

  def client(*clients) = FallbackExplorerClient.new(chains(:arc), *clients)

  test "returns the first client's result and skips the rest" do
    second = verified("Second")
    assert_equal({ name: "First" }, client(verified("First"), second).fetch_contract_info(ADDRESS))
    assert_equal 0, second.calls
  end

  test "falls through to the next client when the first has it unverified" do
    assert_equal({ name: "NativeFiatTokenV2_2" }, client(not_verified, verified("NativeFiatTokenV2_2")).fetch_contract_info(ADDRESS))
  end

  test "falls through past an outage too" do
    assert_equal({ name: "Permit2" }, client(outage, verified("Permit2")).fetch_contract_info(ADDRESS))
  end

  test "raises NotVerifiedError only when every client says unverified" do
    assert_raises(ExplorerClient::NotVerifiedError) { client(not_verified, not_verified).fetch_contract_info(ADDRESS) }
  end

  test "an outage wins over not-verified so it is not shown as an unverified contract" do
    error = assert_raises(ExplorerClient::Error) { client(not_verified, outage).fetch_contract_info(ADDRESS) }
    refute_kind_of ExplorerClient::NotVerifiedError, error
    assert_equal "rate limited", error.message
  end

  test "has no logs endpoint" do
    refute client(verified("X")).logs_supported?
  end

  test "Arc end to end: Sourcify 404, then Etherscan V2 with chainid 5042 serves USDC" do
    stub_request(:get, %r{sourcify\.dev/server/v2/contract/5042/#{ADDRESS}}).to_return(
      status: 404, body: { match: nil }.to_json, headers: { "Content-Type" => "application/json" }
    )
    etherscan = stub_request(:get, %r{api\.etherscan\.io/v2/api}).with(query: hash_including(chainid: "5042", action: "getsourcecode")).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { status: "1", message: "OK", result: [ {
        "ContractName" => "NativeFiatTokenV2_2", "CompilerVersion" => "v0.6.12", "SourceCode" => "contract NativeFiatTokenV2_2 {}",
        "ABI" => [ { "type" => "function", "name" => "totalSupply", "inputs" => [], "outputs" => [ { "type" => "uint256" } ] } ].to_json,
        "Proxy" => "0", "Implementation" => ""
      } ] }.to_json
    )

    stub_request(:get, %r{api\.etherscan\.io/v2/api}).with(query: hash_including(chainid: "5042", action: "getabi")).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { status: "1", message: "OK",
              result: [ { "type" => "function", "name" => "totalSupply", "inputs" => [], "outputs" => [ { "type" => "uint256" } ] } ].to_json }.to_json
    )

    info = chains(:arc).explorer_client.fetch_contract_info(ADDRESS)

    assert_requested etherscan
    assert_equal "NativeFiatTokenV2_2", info[:name]
    assert_equal "totalSupply", info[:abi].first["name"]
  end
end
