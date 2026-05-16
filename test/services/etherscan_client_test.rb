require "test_helper"

class EtherscanClientTest < ActiveSupport::TestCase
  setup do
    @chain = chains(:ethereum)
    @client = EtherscanClient.new(@chain)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
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

  test "fetch_contract_info extracts NatSpec from source" do
    stub_etherscan_source(verified: true, source_code: <<~SOL)
      contract Uni {
        /// @notice Total tokens in circulation.
        /// @return The amount.
        function totalSupply() external view returns (uint256) {}
      }
    SOL
    stub_etherscan_abi

    info = @client.fetch_contract_info("0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")

    assert_kind_of Hash, info[:natspec]
    assert_equal "Total tokens in circulation.", info[:natspec].dig("functions", "totalSupply", "notice")
    assert_equal [ "The amount." ], info[:natspec].dig("functions", "totalSupply", "returns")
  end

  test "fetch_contract_info returns nil implementation_address for non-proxy" do
    stub_etherscan_source(verified: true)
    stub_etherscan_abi

    info = @client.fetch_contract_info("0x1f9840a85d5af5bf1d1762f925bdaddc4201f984")

    assert_nil info[:implementation_address]
  end

  # ──────────────────────────────────────────────
  # get_logs (Etherscan V2 logs/getLogs wrapper)
  # ──────────────────────────────────────────────

  test "get_logs returns the parsed result array on success" do
    log = { "address" => "0x" + "1" * 40, "topics" => [ "0x" + "a" * 64 ], "data" => "0x" }
    stub_logs_response(status: "1", message: "OK", result: [ log ])

    result = @client.get_logs(address: "0x" + "1" * 40, from_block: 1, to_block: 100)

    assert_equal [ log ], result
  end

  test "get_logs returns [] (not error) when Etherscan reports no records" do
    stub_logs_response(status: "0", message: "No records found", result: [])

    result = @client.get_logs(address: "0x" + "1" * 40, from_block: 1, to_block: 100)

    assert_equal [], result, "empty result is normal — must not raise"
  end

  test "get_logs raises Error on non-records-found failures (e.g. bad API key)" do
    stub_logs_response(status: "0", message: "NOTOK", result: "Invalid API Key")

    assert_raises(EtherscanClient::Error) do
      @client.get_logs(address: "0x" + "1" * 40, from_block: 1, to_block: 100)
    end
  end

  test "get_logs forwards topic0 as a query parameter when given" do
    seen_query = nil
    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      seen_query = req.uri.query
      { status: 200, body: empty_logs_body, headers: { "Content-Type" => "application/json" } }
    end

    @client.get_logs(address: "0xabc", from_block: 1, to_block: 100, topic0: "0x" + "1" * 64)

    assert_includes seen_query, "topic0=0x#{'1' * 64}"
  end

  test "get_logs omits topic0 when not given" do
    seen_query = nil
    stub_request(:get, /api\.etherscan\.io/).to_return do |req|
      seen_query = req.uri.query
      { status: 200, body: empty_logs_body, headers: { "Content-Type" => "application/json" } }
    end

    @client.get_logs(address: "0xabc", from_block: 1, to_block: 100)

    refute_includes seen_query.to_s, "topic0=", "absent topic0 must not become an empty query param"
  end

  test "get_logs caches by full param tuple and skips HTTP on hit" do
    stub = stub_logs_response(status: "1", message: "OK", result: [])

    @client.get_logs(address: "0xabc", from_block: 1, to_block: 100)
    @client.get_logs(address: "0xabc", from_block: 1, to_block: 100)

    assert_requested stub, times: 1, times_msg: "second identical call must be served from Solid Cache"
  end

  test "get_logs cache key separates different addresses" do
    stub = stub_logs_response(status: "1", message: "OK", result: [])

    @client.get_logs(address: "0xaaa", from_block: 1, to_block: 100)
    @client.get_logs(address: "0xbbb", from_block: 1, to_block: 100)

    assert_requested stub, times: 2, times_msg: "different addresses must miss the cache independently"
  end

  test "fetch_contract_info resolves proxy to implementation" do
    proxy_addr = "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9"
    impl_addr  = "0x5d4aa78b08bc7c530e21bf7447988b1be7991322"

    stub_etherscan_proxy_source(proxy: proxy_addr, implementation: impl_addr)
    stub_etherscan_impl_source(impl: impl_addr, name: "AaveTokenV3", compiler: "v0.8.10")
    stub_etherscan_abi_for(impl_addr, abi: '[{"type":"function","name":"balanceOf"}]')

    info = @client.fetch_contract_info(proxy_addr)

    assert_equal "AaveTokenV3", info[:name]
    assert_equal "v0.8.10", info[:compiler_version]
    assert_equal impl_addr, info[:implementation_address]
    assert_equal "balanceOf", info[:abi].first["name"]
  end

  private

  def stub_etherscan_source(verified:, source_code: "contract Uni {}")
    body = if verified
      {
        "status" => "1", "message" => "OK",
        "result" => [ {
          "ContractName" => "Uni",
          "CompilerVersion" => "v0.5.16",
          "SourceCode" => source_code,
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

  def stub_etherscan_proxy_source(proxy:, implementation:)
    body = {
      "status" => "1", "message" => "OK",
      "result" => [ {
        "ContractName" => "InitializableAdminUpgradeabilityProxy",
        "CompilerVersion" => "v0.6.10",
        "SourceCode" => "contract Proxy {}",
        "ABI" => '[{"type":"function","name":"admin"}]',
        "Proxy" => "1",
        "Implementation" => implementation
      } ]
    }

    stub_request(:get, /api\.etherscan\.io.*getsourcecode/)
      .with(query: hash_including(address: proxy))
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_etherscan_impl_source(impl:, name:, compiler:)
    body = {
      "status" => "1", "message" => "OK",
      "result" => [ {
        "ContractName" => name,
        "CompilerVersion" => compiler,
        "SourceCode" => "contract #{name} {}",
        "ABI" => '[{"type":"function","name":"balanceOf"}]',
        "Proxy" => "0",
        "Implementation" => ""
      } ]
    }

    stub_request(:get, /api\.etherscan\.io.*getsourcecode/)
      .with(query: hash_including(address: impl))
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_etherscan_abi_for(address, abi:)
    body = { "status" => "1", "message" => "OK", "result" => abi }

    stub_request(:get, /api\.etherscan\.io.*getabi/)
      .with(query: hash_including(address: address))
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_logs_response(status:, message:, result:)
    body = { "status" => status, "message" => message, "result" => result }
    stub_request(:get, /api\.etherscan\.io.*getLogs/i).to_return(
      status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" }
    )
  end

  def empty_logs_body
    { "status" => "0", "message" => "No records found", "result" => [] }.to_json
  end
end
